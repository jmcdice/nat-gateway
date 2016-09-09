#!/usr/bin/bash
#
# Insert a nat rule to our existing nat-gateway VM's.
# This is part of the nat-gateway framework, located here:
# http://stash.cloud-band.com/projects/CBPOC/repos/cb-poc/browse?at=refs%2Fheads%2Fvz_nat
# Only run me from a rocks frontend.
# Joey <joey.mcdonald@nokia.com>
# Ken <ken.fischer@nokia.com>

source /root/keystonerc_admin

# o post port
# r pre port
# VM NAME

while getopts "n:o:r:" opt; do
   case "$opt" in
      o) POST_PORT=$OPTARG   # The real port of the service
      ;;
      r) PRE_PORT=$OPTARG    # The incoming NAT'd port of the service
      ;;
      n) VM_NAME=$OPTARG     # Name of the VM we're going to do NAT for.
      ;;
   esac
done

# Make sure they enter everything we need to run.
function usage() {

   echo "Add a customer nat rule to the existing NAT gateway VM's."
   echo ""
   echo "   $0 -o <destination port> -r <arriving port> -n <vm name>"
   echo ""
   exit 0
}

if [[ -z $POST_PORT || -z $PRE_PORT || -z $VM_NAME ]]; then
   usage
fi

VM_IP=$(nova list --all-tenants |grep $VM_NAME | perl -lane 'print $1 if (/=(.*?)\s/)')

if [ -z $VM_IP ]; then
   echo "Failure: Can't determine the IP for $VM_NAME"
   exit 255
fi

# DEBUG echo "Post: $POST_PORT Pre: $PRE_PORT VM: $VM_NAME VMIP: $VM_IP"

GW_COUNT=$(nova list |grep nat-gateway|awk '{print $4}'|wc -l)

if [ $GW_COUNT -lt '1' ]; then
   echo "Failure: I don't see any nat-gateway VM's running."
   exit 227
fi

echo "Found: $GW_COUNT NAT Gateway VM's"

function add_nat_rule() {

   echo -n "Adding a security group rule to allow $PRE_PORT access to nat-gateway VM's:"
   neutron security-group-rule-create --direction ingress --ethertype IPv4 \
          --protocol tcp --port-range-min $PRE_PORT --port-range-max $PRE_PORT vzgw &> /dev/null
   echo "Ok"
   
   
   # Detect if we're running a single or double VM deployment.
   for vm in `nova list |grep nat-gateway|awk '{print $4}'`; do
      mgt_nat_ip=$(nova list|egrep $vm |perl -lane 'print $1 if (/cb-management=(.*?)\;/)')
      edn_nat_ip=$(nova list|egrep $vm |perl -lane 'print $1 if (/x_edn=(.*?)\s/)')
   
      login="ssh -i /root/.ssh/vzgw_id_rsa $mgt_nat_ip "
      test_login="ssh -i /root/.ssh/vzgw_id_rsa $tst_nat_ip "
   
      #$login 'iptables -F' &> /dev/null
   
      echo -n "$vm: Adding Custom NAT Rule: "
      $login "iptables -t nat -A PREROUTING -p tcp -m tcp -d $edn_nat_ip --dport $PRE_PORT -j DNAT --to-destination $VM_IP:$POST_PORT"
      $login "iptables -t nat -A POSTROUTING -o eth0 -p tcp -m tcp -d $VM_IP --dport $POST_PORT -j SNAT --to-source $mgt_nat_ip"
      echo "Ok"
   
      $login 'service iptables save' &> /dev/null
   done
}
   
function test_rule() {

   for vm in `nova list |grep nat-gateway|awk '{print $4}'`; do
      mgt_nat_ip=$(nova list|egrep $vm |perl -lane 'print $1 if (/cb-management=(.*?)\;/)')
      edn_nat_ip=$(nova list|egrep $vm |perl -lane 'print $1 if (/x_edn=(.*?)\s/)')
   
      # Figure out from where to test this setup.
      echo $vm | grep -q 'nat-gateway-1'
      if [ $? == '0' ]; then
         testvm='nat-gateway-2'
      else
         testvm='nat-gateway-1'
      fi
   
      echo "DEBUG: Testing: $vm from $testvm"
   
      tst_nat_ip=$(nova list|egrep $testvm |perl -lane 'print $1 if (/cb-management=(.*?)\;/)')
   
      test_login="ssh -i /root/.ssh/vzgw_id_rsa $tst_nat_ip "
   
      # Test our rule
      echo -n "$vm: Testing NAT rule: "
      $test_login "timeout 1 bash -c 'cat < /dev/null > /dev/tcp/$edn_nat_ip/$PRE_PORT' && echo $?" 2>/dev/null | grep -q 0
   
      if [ $? == '0' ]; then
         echo "Success"
      else
         echo "Failed"
      fi
      done
}

add_nat_rule
test_rule
