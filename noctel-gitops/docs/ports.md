MICROSERVICES_PORTS.md

Pull requests


Source

source:main


de9375c
noctel-standards/
MICROSERVICES_PORTS.md

BlameEdit

NocTel 7 Microservices Port Assignments
All NT7 microservices use ports in the 7000 series.

Port Assignments
Port	Service	Description
7000	noctel-api	Main NT7 API gateway
7001	noctel-ui	Web UI (Angular)
7010	noctel-billing	Billing system
7011	noctel-billing-worker	Billing background worker (if separate)
7020	noctel-now	Real-time presence/tracking
7021	noctel-now-redis-ws	Now WebSocket server
7022	noctel-now-tracker	GPS tracker ingestion
7030	noctel-flow	Contact center
7040	noctel-alert	Notification service
7050	noctel-dex	Directory/collaboration
7060	noctel-insight	Analytics
7070	noctel-transcribe	Transcription service
7080	noctel-api-fax-in	Inbound fax (T.30)
7081	noctel-api-fax-out	Outbound fax (T.30)
7082	noctel-fma	FMA device integration (FaxBack/ATA)
7090	noctel-notify	Email notifications
7091	noctel-notify-email	Email worker
API Microservices (7100-7199)
Service	HTTP	WS	Health	Description
noctel-api-gateway	7100	7101	9100	Central auth, routing, WebSocket hub
noctel-api-account	7110	-	9110	User/account management
noctel-api-lns	7120	-	9120	LNS REST API
noctel-api-notify	7130	-	9130	Notification REST API
noctel-api-dex	7140	-	9140	Display/menu REST API
noctel-api-mailbox	7150	-	9150	Mailbox REST API
noctel-api-workflow	7160	-	9160	Workflow REST API
noctel-api-storage	7170	-	9170	Storage REST API
Workers (Health Port Only)
Service	Health Port	Description
noctel-api-chirp-in	9125	MISSION-CRITICAL ChirpStack event processor (RabbitMQ consumer)
noctel-lns	-	LNS provisioning worker (Chirpstack gRPC operations)
Reserved Ranges
Range	Purpose
7000-7009	Core API and UI
7010-7019	Billing
7020-7029	Now (presence/tracking)
7030-7039	Flow (contact center)
7040-7049	Alert (notifications)
7050-7059	Dex (directory)
7060-7069	Insight (analytics)
7070-7079	Transcription
7080-7089	Fax
7090-7099	Notify/Email
7100-7199	API Microservices (gateway + extracted services)
9100-9199	Health/Metrics for API Microservices (mirrors 7100 series)
Notes
All services should use the PORT environment variable to override defaults
In Kubernetes, services typically run on their default ports within pods
Load balancers/ingress handle external port mapping
Health checks available at /health on each service
Health/Metrics Ports: API microservices use health ports that mirror their service port (7100→9100, 7110→9110, etc.) to avoid conflicts in local development
API Gateway Pattern: External traffic routes through noctel-api-gateway (7100), which handles auth and forwards to internal services
WebSocket Connections: All WebSocket connections go through the gateway (7101), which manages subscriptions and broadcasts
Kubernetes Service Discovery
# DNS names within K3S cluster (noctel namespace)
noctel-api-gateway.noctel.svc.cluster.local:7100
noctel-api-account.noctel.svc.cluster.local:7110
noctel-api-lns.noctel.svc.cluster.local:7120
noctel-api-notify.noctel.svc.cluster.local:7130
noctel-api-dex.noctel.svc.cluster.local:7140
noctel-api-mailbox.noctel.svc.cluster.local:7150
noctel-api-workflow.noctel.svc.cluster.local:7160
noctel-api-storage.noctel.svc.cluster.local:7170

