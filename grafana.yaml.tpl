# Grafana for one tenant, deployed inside the tenant vCluster.
# The only datasource is the tenant's own locked endpoint (default/tenant-metrics),
# so even a Grafana admin can only ever query that tenant's series.
apiVersion: v1
kind: Namespace
metadata:
  name: grafana
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-provisioning
  namespace: grafana
data:
  datasource.yaml: |
    apiVersion: 1
    datasources:
      - name: Tenant Metrics
        uid: tenant-prom
        type: prometheus
        access: proxy
        url: http://tenant-metrics.default.svc:8080
        isDefault: true
        editable: false
  dashboards.yaml: |
    apiVersion: 1
    providers:
      - name: tenant
        folder: ""
        type: file
        options:
          path: /var/lib/grafana/dashboards
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: grafana
  namespace: grafana
spec:
  replicas: 1
  selector:
    matchLabels:
      app: grafana
  template:
    metadata:
      labels:
        app: grafana
    spec:
      containers:
        - name: grafana
          image: grafana/grafana:12.0.2
          ports:
            - containerPort: 3000
          env:
            # Lab only. Use a Secret and SSO for anything real.
            - name: GF_SECURITY_ADMIN_PASSWORD
              value: admin
            - name: GF_USERS_DEFAULT_THEME
              value: light
          readinessProbe:
            httpGet:
              path: /api/health
              port: 3000
          resources:
            requests:
              cpu: 50m
              memory: 256Mi
          volumeMounts:
            - name: provisioning
              mountPath: /etc/grafana/provisioning/datasources/datasource.yaml
              subPath: datasource.yaml
            - name: provisioning
              mountPath: /etc/grafana/provisioning/dashboards/dashboards.yaml
              subPath: dashboards.yaml
            - name: dashboards
              mountPath: /var/lib/grafana/dashboards
      volumes:
        - name: provisioning
          configMap:
            name: grafana-provisioning
        - name: dashboards
          configMap:
            name: grafana-dashboards
---
apiVersion: v1
kind: Service
metadata:
  name: grafana
  namespace: grafana
spec:
  selector:
    app: grafana
  ports:
    - port: 3000
      targetPort: 3000
