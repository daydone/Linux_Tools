# Network Routing Changes - Rollback Procedure

**Date:** October 14, 2025
**Backup Location:** `/root/backup-*` on each node
**Changes Made:** Multi-VLAN routing configuration for k3s cluster

---

## Quick Rollback (If Things Break Immediately)

### On pdx2-kworker0:

```bash
# Restore original default route
ip route del default via 10.0.96.1 dev bond0.604 2>/dev/null || true
ip route add default via 10.0.99.1 dev bond0.679

# Remove policy routing rules we added
ip rule del from 10.0.99.0/24 table 679 2>/dev/null || true
ip route flush table 679

# Verify routing is back to original
ip route show
ip rule show
```

### On pdx2-kserver0 (if changes were applied):

```bash
# Restore original default route
ip route del default via 10.0.96.1 dev bond0.604 2>/dev/null || true
ip route add default via 10.0.99.1 dev bond0.679

# Remove policy routing rules
ip rule del from 10.0.99.0/24 table 679 2>/dev/null || true
ip route flush table 679

# Verify
ip route show
ip rule show
```

### Test Prod Immediately After Rollback:

```bash
curl -I https://portal.noctel.com
curl -I https://api.noctel.com
```

---

## Full Rollback Using Backups

### On pdx2-kworker0:

```bash
cd /root

# Step 1: Flush all current routing rules and tables
ip rule flush
ip route flush table 677
ip route flush table 678
ip route flush table 679

# Step 2: Restore routing rules from backup
cat backup-ip-rules-pdx2-kworker0-20251014.txt | while read line; do
  # Skip the default rules (0, 32766, 32767) as they're built-in
  priority=$(echo "$line" | awk '{print $1}' | tr -d ':')
  if [[ "$priority" != "0" && "$priority" != "32766" && "$priority" != "32767" ]]; then
    rule=$(echo "$line" | cut -d: -f2-)
    ip rule add $rule 2>/dev/null || true
  fi
done

# Step 3: Restore main routing table
ip route flush table main
grep -v "table" backup-ip-routes-pdx2-kworker0-20251014.txt | grep -v "^$" | while read route; do
  ip route add $route 2>/dev/null || true
done

# Step 4: Restore iptables if needed
iptables-restore < backup-iptables-pdx2-kworker0-20251014.txt

# Step 5: Restore firewalld if needed
systemctl restart firewalld

# Step 6: Verify routing
ip route show
ip rule show
ip route show table all
```

### On pdx2-kserver0:

```bash
cd /root

# Same steps as kworker0
ip rule flush
ip route flush table 677
ip route flush table 678
ip route flush table 679

cat backup-ip-rules-pdx2-kserver0-20251014.txt | while read line; do
  priority=$(echo "$line" | awk '{print $1}' | tr -d ':')
  if [[ "$priority" != "0" && "$priority" != "32766" && "$priority" != "32767" ]]; then
    rule=$(echo "$line" | cut -d: -f2-)
    ip rule add $rule 2>/dev/null || true
  fi
done

ip route flush table main
grep -v "table" backup-ip-routes-pdx2-kserver0-20251014.txt | grep -v "^$" | while read route; do
  ip route add $route 2>/dev/null || true
done

iptables-restore < backup-iptables-pdx2-kserver0-20251014.txt
systemctl restart firewalld

# Verify
ip route show
ip rule show
```

---

## Nuclear Option: Reboot

If routing is completely broken and manual restoration doesn't work:

```bash
# On each affected node:
reboot
```

**Note:** After reboot, routing will revert to the configuration defined in `/etc/sysconfig/network-scripts/` files. If we made those persistent, you'll need to remove them before rebooting.

---

## Verify Services After Rollback

### Check Kubernetes Services:

```bash
kubectl get pods --all-namespaces -o wide
kubectl get svc --all-namespaces | grep LoadBalancer
```

### Check MetalLB:

```bash
kubectl get pods -n metallb-system
kubectl logs -n metallb-system -l component=speaker --tail=50
```

### Test Prod Accessibility:

```bash
# From pdx2-kserver0 or pdx2-kworker0:
curl -I https://portal.noctel.com
curl -I https://api.noctel.com

# From your laptop:
curl -I https://portal.noctel.com
curl -I https://api.noctel.com
```

---

## If Rollback Fails

### Contact Information:
- Network Engineer: [contact info]
- Backup files location: `/root/backup-*` on each node
- Backup date: 2025-10-14

### Emergency Steps:
1. Check if you can SSH to nodes
2. If SSH works, try manual routing restoration
3. If routing is completely broken, console access may be needed
4. Last resort: Physical access to restore from backups or reboot

---

## Post-Rollback Checklist

- [ ] Prod portal accessible (https://portal.noctel.com)
- [ ] Prod API accessible (https://api.noctel.com)
- [ ] All LoadBalancer services have IPs assigned
- [ ] All pods are running
- [ ] MetalLB speakers are healthy
- [ ] No errors in Cilium logs
- [ ] Firewall sessions can be created

---

## Files Modified (If Persistence Was Configured)

If we configured persistent routing, these files would need to be removed/reverted:

```bash
# Remove these files if they were created:
rm -f /etc/sysconfig/network-scripts/route-bond0.677
rm -f /etc/sysconfig/network-scripts/route-bond0.678
rm -f /etc/sysconfig/network-scripts/route-bond0.679
rm -f /etc/sysconfig/network-scripts/rule-bond0.677
rm -f /etc/sysconfig/network-scripts/rule-bond0.678
rm -f /etc/sysconfig/network-scripts/rule-bond0.679
rm -f /etc/sysctl.d/99-metallb.conf

# Then reboot for clean state
reboot
```

---

## Notes

- Backups were taken on: **2025-10-14**
- Original default route: **10.0.99.1 via bond0.679**
- Original policy routes: Tables 677 and 678 were already configured
- Prod was working before changes
- QA was NOT working before changes (this is what we're trying to fix)
