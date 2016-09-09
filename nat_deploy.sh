#!/usr/bin/bash
#
# Deploy the node gateway system.
# Joey <joey.mcdonald@nokia.com>
# Ken <ken.fischer@nokia.com>


# Modify for your environment.
# 10.139.81.0/26
EDN_VLAN='2009'				# The EDN VLAN ID
EDN_SUB='10.139.81.0/26'		# The EDN network and CIDR prefix
EDN_GW='10.139.81.1'			# The EDN network gateway
EDN_START_RANGE='10.139.81.47'		# The Start IP range (must be contiguious)
EDN_END_RANGE='10.139.81.50' 		# The End IP range (must be contiguious)

EDN_V6_SUB='2001:4888:a06:7142::/64'    # The v6 subnet for x_edn

# Need at least 5 addresses here.
CBM_START_RANGE='135.104.67.20'		# Start IP range for rocks 'public'
CBM_END_RANGE='135.104.67.25'        	# End IP range for rocks 'public'

# Shouldn't have to edit below here.

# Pull in admin credentials
source /root/keystonerc_admin

# Provide a number of VM's to 'd'eploy. You can choose as many if you
# want. If non are chosen, we'll default to 1
while getopts "d:" opt; do
   case "$opt" in
      d) GW=$OPTARG
      ;;
   esac
done

if [ -z "$GW" ]; then
   GW='1'
fi

function verify_creds() {

   # Test to check for admin creds.
   echo -n "Verifying admin credentials: "
   env | grep -q OS_AUTH_URL
   check_exit_code
}

function create_sec_group() {

   echo -n "Creating a security group: "
   # Create the vzgw group
   neutron security-group-create vzgw &> /dev/null
   # Allow ssh
   neutron security-group-rule-create --direction ingress --ethertype IPv4 \
       --protocol tcp --port-range-min 22 --port-range-max 22 vzgw &> /dev/null
   # Allow http
   neutron security-group-rule-create --direction ingress --ethertype IPv4 \
       --protocol tcp --port-range-min 7443 --port-range-max 7443 vzgw &> /dev/null
   # Allow 443
   neutron security-group-rule-create --direction ingress --ethertype IPv4 \
       --protocol tcp --port-range-min 443 --port-range-max 443 vzgw &> /dev/null
   # Allow 8443
   neutron security-group-rule-create --direction ingress --ethertype IPv4 \
       --protocol tcp --port-range-min 8443 --port-range-max 8443 vzgw &> /dev/null
   # Allow ICMP
   neutron security-group-rule-create --direction ingress --ethertype IPv4 \
       --protocol icmp vzgw &> /dev/null

   neutron security-group-list | grep -q vzgw
   check_exit_code
}

function create_provider_network() {

   echo -n "Checking for provider network: "
   neutron net-list | grep -q cb-management

   if [ $? != '0' ]; then

      # This bit of code discovers everything we need to know about the 'provider' network.
      # The only thing we can't really discover is what IP's we can use for guest VM's.
      conf='/export/ci/cluster-config.txt'
      network=$(grep ^NETWORK: $conf | awk '{print $2}')
      netmask=$(grep ^NETMASK: $conf | awk '{print $2}')
      gateway=$(grep ^GATEWAY: $conf | awk '{print $2}')
      prefix=$(/bin/ipcalc -p $network $netmask|awk -F\= '{print $2}')
      dns=$(grep nameserver /etc/resolv.conf |tail -1|awk '{print $2}')
      CBM_SUB="$network/$prefix"
      CBM_GW="$gateway"

      # Given these three, I think we can calculate the start and end ranges but
      # for now, the users can decide for themselfs. 
      computes=$(rocks list host compute | grep ^compute|wc -l)
      start_computes=$(grep IP_PUBLIC_COMPUTE0: $conf|awk '{print $2}')
      broadcast=$(/bin/ipcalc -b $network $netmask|awk -F\= '{print $2}')

      echo "Installing ($CBM_SUB)"

      neutron net-create cb-management --provider:network_type flat \
          --provider:physical_network RegionOne --router:external=True  &> /dev/null

      neutron subnet-create --name cb-management-subnet --allocation-pool \
          start=$CBM_START_RANGE,end=$CBM_END_RANGE --gateway $gateway cb-management $CBM_SUB \
          --dns_nameservers list=true $dns &> /dev/null

   else
      echo "Ok"
   fi
}


function create_networks() {

   echo -n "Creating EDN network: "

   neutron net-create x_edn --provider:physical_network RegionOne --provider:network_type \
      vlan --provider:segmentation_id $EDN_VLAN &> /dev/null

   neutron subnet-create x_edn $EDN_SUB --name subnet1 \
      --allocation-pool start=$EDN_START_RANGE,end=$EDN_END_RANGE \
      --disable-dhcp --gateway $EDN_GW &> /dev/null

   neutron net-list | grep -q x_edn
   check_exit_code
}

function add_v6_subnet() {

   echo -n "Adding v6 subnet to x_edn: "
   neutron subnet-create x_edn $EDN_V6_SUB --name v6subnet1 \
       --ip-version 6 &> /dev/null
   echo "Ok"
}


function boot_vm() {
   inst=$1

   nova boot $inst  \
     --image $(nova image-list|grep redhat6 |awk '{print $2}') \
     --flavor $(nova flavor-list | grep default |  awk '{print $2}') \
     --nic net-id=$(neutron net-list | grep cb-management | awk '{print $2}') \
     --nic net-id=$(neutron net-list | grep x_edn | awk '{print $2}') \
     --key_name vzgw-key \
     --security_groups vzgw  &> /dev/null
}

function create_ssh_key() {

   echo -n "Checking crypto keys: "
   if [ ! -f ~/.ssh/vzgw_id_rsa.pub ]; then
      echo "Installing"
      ssh-keygen -N '' -f ~/.ssh/vzgw_id_rsa &> /dev/null
      chmod 600 -f ~/.ssh/cf_id_rsa
      nova keypair-add --pub-key ~/.ssh/vzgw_id_rsa.pub vzgw-key &> /dev/null
   else
      echo "Ok"
   fi
}


function clean_up() {

   for vm in `nova list |grep nat-gateway|awk '{print $4}'`; do
      ip=$(nova list|egrep $vm |perl -lane 'print $1 if (/cb-management=(.*?)\;/)')
      cat /root/.ssh/known_hosts|grep -v $ip > /tmp/known_hosts
      cat /tmp/known_hosts > /root/.ssh/known_hosts
      rm -f /tmp/known_hosts
   done

   for uuid in `nova list |grep nat-gateway|awk '{print $4}'`
   do
      nova delete $uuid
   done

   sleep 5

   for port in `neutron port-list|grep smsriovport|awk '{print $2}'`
   do
      neutron port-delete $port
   done

   for net in `neutron net-list|egrep 'x_edn|cb-management' |awk '{print $2}'`
   do
      neutron net-delete $net
   done

   for key in `nova keypair-list|grep vzgw|awk '{print $2}'`
   do
      nova keypair-delete $key
      rm -f /root/.ssh/vzgw_id_rsa
      rm -f /root/.ssh/vzgw_id_rsa.pub
   done

   for uuid in `nova secgroup-list | grep vzgw|awk '{print $2}'`
   do
      nova secgroup-delete $uuid &> /dev/null
   done
}

function wait_for_running() {

   echo -n "Waiting for VM 'Running' status: "
   sleep 5

   # If we don't get this far, boot failure occured.
   nova list | grep -q nat-gateway-[0-9]
   if [ $? -ne 0 ]; then
      echo "Failed to boot VM"
      clean_up
      exit 255
   fi

   for i in {1..30}; do
      nova list | grep gateway-[0-9] | grep -q ACTIVE
      if [ $? != 0 ]; then
         sleep 5
      else
         echo "Success"
         nova list|grep gateway-[0-9] | awk -F\| '{print $3 $7}'
         return
      fi
   done
   echo "Failed."
   clean_up
   exit 255
}

function wait_for_ssh() {

   for vm in `nova list |grep nat-gateway|awk '{print $4}'`; do
      echo -n "Waiting for $vm network access: "
      ip=$(nova list|egrep $vm |perl -lane 'print $1 if (/cb-management=(.*?)\;/)')
      ssh -i /root/.ssh/vzgw_id_rsa $ip 'date' &> /dev/null
      while test $? -gt 0; do
         sleep 5
         ssh -i /root/.ssh/vzgw_id_rsa $ip 'date' &> /dev/null
      done
      echo "Ok"
   done
}

function assign_edn_ip() {

   SUBNET=$(ipcalc -m $EDN_SUB|awk -F\= '{print $2}')
   # Cant spare an IP for dhcp so assign interface IP's manually.
   for vm in `nova list |grep nat-gateway|awk '{print $4}'`; do
      mgt_nat_ip=$(nova list|egrep $vm |perl -lane 'print $1 if (/cb-management=(.*?)\;/)')
      edn_nat_ip=$(nova list|egrep $vm |perl -lane 'print $1 if (/x_edn=(.*?)\s/)')
   echo "Assigning: $edn_nat_ip/$SUBNET to $vm"

cat << EOF > /tmp/ifcfg-eth1
DEVICE=eth1
BOOTPROTO=none
ONBOOT=yes
NETMASK=$SUBNET
IPADDR=$edn_nat_ip
USERCTL=no
EOF

      scp -i /root/.ssh/vzgw_id_rsa -q /tmp/ifcfg-eth1 $mgt_nat_ip:/etc/sysconfig/network-scripts/
      ssh -i /root/.ssh/vzgw_id_rsa $mgt_nat_ip 'ifup eth1' &> /dev/null

      # Set the gw to the EDN side
      ssh -i /root/.ssh/vzgw_id_rsa $mgt_nat_ip 'route delete default' &> /dev/null
      ssh -i /root/.ssh/vzgw_id_rsa $mgt_nat_ip "route add default gw $EDN_GW" &> /dev/null
      ssh -i /root/.ssh/vzgw_id_rsa $mgt_nat_ip "echo 'GATEWAY=$EDN_GW' >> /etc/sysconfig/network " &> /dev/null

   done
}

function create_nats() {

   os_vip=$(pcs config | grep -A1 'Resource: vip_openstack_public_endpoint'|head -2|perl -lane 'print $1 if (/Attributes: ip=(.*?)\s/)')
   cb_vip=$(pcs config | grep -A1 'Resource: vip_cb_fe'|perl -lane 'print $1 if (/Attributes: ip=(.*?)\s/)')

   # Detect if we're running a single or double VM deployment.
   for vm in `nova list |grep nat-gateway|awk '{print $4}'`; do
      mgt_nat_ip=$(nova list|egrep $vm |perl -lane 'print $1 if (/cb-management=(.*?)\;/)')
      edn_nat_ip=$(nova list|egrep $vm |perl -lane 'print $1 if (/x_edn=(.*?)\s/)')

      feip=$(facter|grep ipaddress_br1|awk '{print $3}')
      login="ssh -i /root/.ssh/vzgw_id_rsa $mgt_nat_ip "
      test_login="ssh -i /root/.ssh/vzgw_id_rsa $tst_nat_ip "

      # Forward packets for us in a way that survives reboots
      $login 'echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf' &> /dev/null
      $login 'sysctl -p' &> /dev/null

      $login 'service iptables restart' &> /dev/null                          
      $login 'iptables -F' &> /dev/null

      # OpenStack Horizon NAT
      echo -n "$vm: Adding NAT for OpenStack Horizon: "
      $login "iptables -t nat -A PREROUTING -p tcp -m tcp -d $edn_nat_ip --dport 443 -j DNAT --to-destination $os_vip"
      $login "iptables -t nat -A POSTROUTING -o eth0 -p tcp -m tcp -d $os_vip --dport 443 -j SNAT --to-source $mgt_nat_ip"
      # This is for VNC html5 console access.
      $login "iptables -t nat -A PREROUTING -p tcp -m tcp -d $edn_nat_ip --dport 6080 -j DNAT --to-destination $os_vip:6080"         |
      $login "iptables -t nat -A POSTROUTING -o eth0 -p tcp -m tcp -d $os_vip --dport 6080 -j SNAT --to-source $mgt_nat_ip"          |
      echo "Ok"

      # Cluster Monitoring Nagios/Ganglia NAT
      echo -n "$vm: Adding NAT for Cluster Monitoring: "
      $login "iptables -t nat -A PREROUTING -p tcp -m tcp -d $edn_nat_ip --dport 7443 -j DNAT --to-destination $feip:80"
      $login "iptables -t nat -A POSTROUTING -o eth0 -p tcp -m tcp -d $feip --dport 80 -j SNAT --to-source $mgt_nat_ip"
      echo "Ok"

      # Infrastructure NAT
      if [ -n "$cb_vip" ]; then
         echo -n "$vm: Adding NAT for Management: "
	 $login "iptables -t nat -A PREROUTING -p tcp -m tcp -d $edn_nat_ip --dport 8443 -j DNAT --to-destination $cb_vip:443"
         $login "iptables -t nat -A POSTROUTING -o eth0 -p tcp -m tcp -d $cb_vip --dport 443 -j SNAT --to-source $mgt_nat_ip"
         echo "Ok"
      fi
   
      $login 'service iptables save' &> /dev/null                          
      done
}

function test_rules() {

   cb_vip=$(pcs config | grep -A1 'Resource: vip_cb_fe'|perl -lane 'print $1 if (/Attributes: ip=(.*?)\s/)')

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

      feip=$(facter|grep ipaddress_br1|awk '{print $3}')
      cbip='' # Figure this out later.
      login="ssh -i /root/.ssh/vzgw_id_rsa $mgt_nat_ip "
      test_login="ssh -i /root/.ssh/vzgw_id_rsa $tst_nat_ip "

      # Test for Horizon
      echo -n "$vm: Testing Openstack Horizon: "
      $test_login "curl -sk https://$edn_nat_ip/|grep -q Description"
      if [ $? == '0' ]; then
         echo "Success"
      else
         echo "Failed"
      fi

      # Test for Monitoring
      echo -n "$vm: Testing Cluster Monitoring: "
      $test_login "curl -sk http://$edn_nat_ip:7443/|grep -q rocksUI"
      if [ $? == '0' ]; then
         echo "Success"
      else
         echo "Failed"
      fi

      # Test for Management UI 
      if [ -n "$cb_vip" ]; then
         echo -n "$vm: Testing Management UI: "
         $test_login "curl -sk https://$edn_nat_ip:8443/|grep -iq document"
         if [ $? == '0' ]; then
            echo "Success"
         else
            echo "Failed"
         fi
      fi

   done
}

function check_exit_code() {

   if [ $? -ne 0 ]; then
      $SMOKE_RES = false
      echo "Failed"
      echo "Running clean up"
      clean_up
      exit 255
   fi
   echo "Success"
}

clean_up
verify_creds
create_sec_group
create_provider_network
create_networks
create_ssh_key

for (( vm='1'; vm<="$GW"; vm++)); do
   echo "Booting VM: nat-gateway-$vm"
   boot_vm "nat-gateway-$vm"
done

wait_for_running
wait_for_ssh
assign_edn_ip
create_nats

if [ "$GW" -gt '1' ]; then
   test_rules
fi

# add_v6_subnet

exit


