# Kubernetes examples

This directory contains two PetClinic deployment variants:

- `petclinic.yml` is the original compact demo manifest.
- `petclinic-optimized.yml` is the slide-friendly example for running the optimized Java image in Kubernetes.

## Build and run locally

Build the optimized image:

```bash
docker build -f docker-image-builds\Dockerfile -t spring-petclinic:optimized-dockerfile .
```

If the cluster runs in `kind`, load the image into the cluster:

```bash
kind load docker-image spring-petclinic:optimized-dockerfile
```

If the cluster runs in `minikube`, load the image into the cluster:

```bash
minikube image load spring-petclinic:optimized-dockerfile
```

Apply the database and application manifests:

```bash
kubectl apply -f k8s\db.yml
kubectl apply -f k8s\petclinic-optimized.yml
kubectl rollout status deployment/petclinic-optimized
kubectl port-forward service/petclinic-optimized 8080:80
```

Open `http://localhost:8080`.

## What this manifest demonstrates

- `startupProbe`, `livenessProbe`, and `readinessProbe` use Spring Boot Actuator health groups.
- `server.shutdown=graceful`, `preStop`, and `terminationGracePeriodSeconds` give the JVM time to finish in-flight requests during rollout.
- `JAVA_TOOL_OPTIONS` derives the heap from the container memory limit instead of a fixed heap size.
- `runAsNonRoot`, `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`, `capabilities.drop: [ALL]`, and `seccompProfile: RuntimeDefault` define the runtime contract for the container.
- `/tmp` is mounted as `emptyDir` because the root filesystem is read-only.

For production, replace the local tag with an immutable registry reference:

```bash
kubectl set image deployment/petclinic-optimized petclinic=registry.example.ru/petclinic@sha256:<digest>
```
