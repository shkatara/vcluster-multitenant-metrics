apiVersion: v1
kind: Namespace
metadata:
  name: payments
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: __NAME__
  namespace: payments
spec:
  replicas: 1
  selector:
    matchLabels:
      app: __NAME__
  template:
    metadata:
      labels:
        app: __NAME__
    spec:
      containers:
        - name: app
          image: nginx:1.29-alpine
          resources:
            requests:
              cpu: 20m
              memory: __MEM__
            limits:
              memory: 128Mi
