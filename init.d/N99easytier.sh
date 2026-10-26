#!/bin/sh
# NAT initialization/rebuild is not a service shutdown event.
# In particular, start_nat must never stop EasyTier or alter its firewall rules.
exit 0
