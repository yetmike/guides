#!/bin/sh
# Where does internet traffic from the private subnet go right now?
aws ec2 describe-route-tables --route-table-ids "$RT" \
  --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'].[NatGatewayId,NetworkInterfaceId]" --output text |
  awk '{ if ($1 != "None") print "0.0.0.0/0 -> " $1 "   (standby NAT Gateway)"; else print "0.0.0.0/0 -> " $2 "   (NAT instance)" }'
