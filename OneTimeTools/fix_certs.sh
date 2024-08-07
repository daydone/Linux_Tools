#!/bin/bash
# Run this from the vCenter Server where data-encipherment certificate is expired and needs to be replaced

echo "Replacing Certificate in data-encipherment VECS Store"

echo ""
PNID=$(/opt/likewise/bin/lwregshell list_values '[HKEY_THIS_MACHINE\Services\vmafd\Parameters]' | grep PNID | awk '{print $4}'|tr -d '"')
echo "Detected PNID: $PNID"

echo ""
PSC=$(/opt/likewise/bin/lwregshell list_values '[HKEY_THIS_MACHINE\Services\vmafd\Parameters]' | grep DCName | awk '{print $4}'|tr -d '"')
echo "Detected PSC: $PSC"

echo ""
echo "Taking backup of old certificate and private key to /tmp directory"
/usr/lib/vmware-vmafd/bin/vecs-cli entry getcert --store data-encipherment --alias data-encipherment --output /tmp/old-data-encipherment.crt
/usr/lib/vmware-vmafd/bin/vecs-cli entry getkey --store data-encipherment --alias data-encipherment --output /tmp/old-data-encipherment.key

echo ""
echo "Deleting the existing certificate from the VECS store"
/usr/lib/vmware-vmafd/bin/vecs-cli entry delete -y --store data-encipherment --alias data-encipherment

echo ""
echo "Generating new certificate using the existing private key and add to the VECS store"
/usr/lib/vmware-vmca/bin/certool --server=$PSC --genCIScert --dataencipherment --privkey=/tmp/old-data-encipherment.key --cert=/tmp/tmp-data-encipherment.crt --Name=data-encipherment --FQDN=$PNID

echo ""
echo "Listing the new certificate in VECS Store"
/usr/lib/vmware-vmafd/bin/vecs-cli entry list --store data-encipherment --text | egrep 'Alias|Serial Number:|Subject:|Not Before|Not After'

echo ""
echo "*************************************************************************************************************************"
echo "  Completed the script execution, please follow the manual steps in case the script fails to replace the Certificate"
echo ""
echo "  VPXD Service needs to be restarted for the changes to take effect, otherwise Guest OS Customizations might fail"
echo "  Please execute following command to restart the service: "
echo ""
echo "  service-control --stop vpxd && service-control --start vpxd "
echo "*************************************************************************************************************************"