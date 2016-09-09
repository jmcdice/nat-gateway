
date=$(date '+%d-%^h-%Y')
archive="nat-gateway-$date.tgz"

cd /root/
tar -zcvf $archive cb-poc --exclude='.git/*'

