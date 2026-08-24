# Docker image builds with Spring Boot plugins

This directory contains standalone build projects that reuse the Spring PetClinic sources from the repository root and build OCI/Docker images through the official Spring Boot build plugins.

These projects intentionally do not use a Dockerfile. They are meant for comparison with the custom multi-stage `jlink` Dockerfiles in the repository root.

## Prerequisites

- Docker daemon is running.
- `JAVA_HOME` points to JDK 21 or newer.

The projects compile PetClinic with Java 21 bytecode and ask buildpacks to put Java 25 into the runtime image through `BP_JVM_VERSION=25`.

## Maven

```powershell
.\mvnw.cmd -f docker-image-builds\maven-build-image\pom.xml -DskipTests spring-boot:build-image
```

Image name:

```text
spring-petclinic:buildpack-maven
```

## Gradle

```powershell
.\gradlew.bat -p docker-image-builds\gradle-boot-build-image bootBuildImage -x test
```

Image name:

```text
spring-petclinic:buildpack-gradle
```

## Optimized Dockerfile

```powershell
docker build -f docker-image-builds\Dockerfile -t spring-petclinic:optimized-dockerfile .
```

Image name:

```text
spring-petclinic:optimized-dockerfile
```

This Dockerfile follows Spring Boot's layered jar recommendations and adds a Java 25 AOT cache training run. It uses the Maven wrapper project from `docker-image-builds/maven-build-image` so the image is comparable with the Maven and Gradle buildpack variants.

## Comparison target

- Plugin builds: Cloud Native Buildpacks, no Dockerfile, less manual control.
- Optimized Dockerfile build: explicit multi-stage Dockerfile, Spring Boot layers, non-root runtime, AOT cache.
- Custom `jlink` builds: explicit Dockerfile, custom base image, `jdeps` + `jlink`, more manual verification.
