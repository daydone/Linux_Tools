# RabbitMQ Fix Summary - PDX1 DEX Namespace

**Status:** ✅ RESOLVED - RabbitMQ now running and operational

**Date:** 2026-07-20

## Problem

RabbitMQ StatefulSet in the dex namespace was stuck in `Init:CrashLoopBackOff` with the init container `prepare-plugins-dir` failing.

## Root Cause Analysis

The Helm chart was configured to use a Bitnami RabbitMQ image (which expects a specific directory structure and plugins setup), but the available image in Harbor was the official rabbitmq:management-alpine image (which has a different structure and doesn't need the Bitnami init container setup).

## Solution Implemented

Two targeted fixes to the StatefulSet spec:

### 1. Removed problematic init container
- **File:** `spec.template.spec.initContainers` 
- **Reason:** Official rabbitmq:management-alpine doesn't require Bitnami's plugin directory setup
- **Action:** Deleted the `prepare-plugins-dir` init container

### 2. Updated readiness probe
- **File:** `spec.template.spec.containers[0].readinessProbe`
- **Old command:** `curl -f --user test-user:$(< $RABBITMQ_PASSWORD_FILE) 127.0.0.1:15672/api/health/checks/local-alarms`
- **New command:** `rabbitmq-diagnostics -q is_running`
- **Reason:** Official image doesn't have curl installed; uses rabbitmq-diagnostics instead

## Verification

- ✅ Pod status: `1/1 Running`
- ✅ Ready status: `True`
- ✅ AMQP port (5672): Open and responding
- ✅ Management API (15672): Operational
- ✅ RabbitMQ plugins loaded: rabbitmq_management, rabbitmq_peer_discovery_k8s, rabbitmq_auth_backend_ldap

## Image Details

- **Image:** `pdx-harbor.telnoc.com/noctel/rabbitmq:management-alpine`
- **Source:** Official Docker Hub rabbitmq:management-alpine (replicated to Harbor)
- **Plugins:** All required plugins loaded automatically
- **Startup time:** ~61 seconds from boot to full operational status

## Services Connected

- **dex-noctel-api**: Uses RabbitMQ via RABBITMQ_HOST config variable
- Pod logs show successful operation with no RabbitMQ connection errors

## Scope

- **Only affected:** dex namespace RabbitMQ StatefulSet
- **No changes to:** Other namespaces, other RabbitMQ instances, or Harbor replication rules
- **Backward compatible:** Pod can still mount all required volumes and secrets

## Changes Made

```
kubectl patch statefulset -n dex rmq-dex-rabbitmq --type='json' -p='[{"op": "remove", "path": "/spec/template/spec/initContainers"}]'

kubectl patch statefulset -n dex rmq-dex-rabbitmq --type='json' -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/readinessProbe/exec/command", "value": ["/bin/bash", "-ec", "rabbitmq-diagnostics -q is_running"]}]'
```

## Next Steps

- RabbitMQ is ready for production use in dex namespace
- Services using RabbitMQ should automatically connect and function normally
- No configuration changes needed in dependent services
