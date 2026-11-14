# Docker image builds with Spring Boot plugins

This directory contains standalone build projects that reuse the Spring PetClinic sources from the repository root and build OCI/Docker images through the official Spring Boot build plugins.

These projects intentionally do not use a Dockerfile. They are meant for comparison with the custom multi-stage `jlink` Dockerfiles in the repository root.

## Prerequisites

- Docker daemon is running.
- `JAVA_HOME` points to JDK 21 or newer.

The projects compile PetClinic with Java 21 bytecode and ask buildpacks to put Java 25 into the runtime image through `BP_JVM_VERSION=25`.

## Maven

```bash
./mvnw -f docker-image-builds\maven-build-image\pom.xml -DskipTests spring-boot:build-image
```

Image name:

```text
spring-petclinic:buildpack-maven
```

The Maven and Gradle examples explicitly select Eclipse Temurin JRE through
`paketobuildpacks/adoptium`, followed by `paketobuildpacks/java`. Buildpack order
matters: Adoptium provides the JVM before the Java composite buildpack checks
its default JVM provider. `BP_JVM_VERSION=25` selects the Java version, not the
vendor. The GraalVM Native Image profile has a separate buildpack list.

Verify the JVM in the built image:

```bash
docker run --rm --entrypoint /layers/paketo-buildpacks_adoptium/jre/bin/java \
  spring-petclinic:buildpack-maven -version
```

Build the GraalVM Native Image variant with the Maven project:

```bash
./mvnw -f docker-image-builds/maven-build-image/pom.xml -Pnative,native-container -DskipTests spring-boot:build-image
```

Image name:

```text
spring-petclinic:native-graalvm
```

## Gradle

```bash
./gradlew -p docker-image-builds\gradle-boot-build-image bootBuildImage -x test
```

Image name:

```text
spring-petclinic:buildpack-gradle
```

The Maven and Gradle buildpack examples use explicit cache volume names:

```text
petclinic-maven-build-cache
petclinic-maven-launch-cache
petclinic-gradle-build-cache
petclinic-gradle-launch-cache
```

This keeps the Cloud Native Buildpacks cache stable even when image tags change
between CI runs.

## Optimized Dockerfile

```bash
docker build -f docker-image-builds\Dockerfile -t spring-petclinic:optimized-dockerfile .
```

Image name:

```text
spring-petclinic:optimized-dockerfile
```

This Dockerfile follows Spring Boot's layered jar recommendations and adds a Java 25 AOT cache training run. It uses the Maven wrapper project from `docker-image-builds/maven-build-image` so the image is comparable with the Maven and Gradle buildpack variants.

There is also a Gradle variant with the same layer extraction strategy:

```bash
docker build -f docker-image-builds\Dockerfile.gradle-cache -t spring-petclinic:optimized-gradle .
```

## BuildKit registry cache

For local Docker builds, the optimized Dockerfiles use BuildKit cache mounts for
Maven or Gradle dependency caches.

For CI, use a registry cache so different runners can reuse the same build
layers:

```bash
./docker-image-builds/scripts/invoke-buildkit-image-build.sh \
  --image registry.example.ru/petclinic:2026.09.15 \
  --cache-ref registry.example.ru/petclinic:buildcache \
  --push
```

The same pattern is shown as a GitHub Actions example in
`docker-image-builds/ci/github-actions-buildkit-cache.yml`.

## Kubernetes runtime profiles

The example manifest compares three deployment profiles:

```bash
kubectl apply -f docker-image-builds/kubernetes/runtime-comparison.yaml
```

- `petclinic-jvm`: the Maven buildpack image with Eclipse Temurin JRE. At a
  `512Mi` memory limit, the example reduces the buildpack thread-count estimate
  and code cache so the JVM leaves room outside the Java heap.
- `petclinic-native`: the GraalVM Native Image variant under the same `512Mi`
  limit. Lower limits should be selected only after a load test.
- `petclinic-aot-cache`: the custom layered Dockerfile with a Java AOT cache.
  The tested profile uses a `768Mi` container limit and `-Xmx512m`; the cache
  did not load at a `512Mi` container limit for this application.

The manifest is a benchmark and tuning starting point, not a universal set of
production requests and limits.
Rebuilding a local image tag does not replace a copy already cached on a
Kubernetes node. Use a new tag for each published build and update the
Deployment, or explicitly reload the image into the local cluster before
restarting Pods. This matters when replacing an existing JVM image with Temurin.

## Recorded measurements

Raw runs, image IDs, startup logs, exact layer sizes and test parameters are in
`measurements/*-2026-10-29.json`. Each image is started three times with one CPU
and a preloaded image. Readiness is the first successful HTTP response from
`/actuator/health`, not the Kubernetes Pod `Ready` transition. Memory is sampled
with `docker stats` five seconds later; there is no application load.

The Temurin buildpack image uses a `512Mi` limit, `BPL_JVM_THREAD_COUNT=50` and
`JAVA_TOOL_OPTIONS=-XX:ReservedCodeCacheSize=64m`. Paketo's memory calculator
sets `-Xmx`; that explicit value takes precedence over `MaxRAMPercentage`.
The thread-count setting is an estimate for memory calculation, not a cap on
the number of Java threads.

Use `docker images -a --tree` for the `CONTENT SIZE` column. The plain `SIZE`
field and uncompressed `docker history` layer sizes are different metrics.
The measured images have different bases and Java versions, so these results
compare complete builds rather than isolate the effect of the JVM vendor.
One preliminary `jlink-axiom` run did not reach HTTP readiness within 180 s;
the cause is unknown. The chart uses a separate successful repeat series.
See `measurements/jlink-preliminary-timeout-2026-10-29.json`; the successful
medians must not be interpreted as proof of startup reliability.

## Comparison target

- Plugin builds: Cloud Native Buildpacks, no Dockerfile, less manual control.
- Optimized Dockerfile build: explicit multi-stage Dockerfile, Spring Boot layers, non-root runtime, AOT cache.
- Native Image build: fast startup and lower idle memory, but a slower and more
  memory-intensive build plus reachability metadata requirements.
- Custom `jlink` builds: explicit Dockerfile, custom base image, `jdeps` + `jlink`, more manual verification.
