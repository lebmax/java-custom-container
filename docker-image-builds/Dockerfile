# syntax=docker/dockerfile:1.7

# Optimized Spring Boot image build:
# 1. Build the application in a separate Maven stage.
# 2. Extract Spring Boot layers with jarmode=tools.
# 3. Copy stable dependency layers before frequently changing application code.
# 4. Create a Java 25 AOT cache during image build.
# 5. Run the final container without Maven, source files, or root privileges.

FROM maven:3.9.16-eclipse-temurin-25 AS build

WORKDIR /workspace

# Copy only the build descriptor first so dependency resolution is cached when
# application source code changes.
COPY docker-image-builds/maven-build-image/pom.xml docker-image-builds/maven-build-image/pom.xml
RUN --mount=type=cache,target=/root/.m2 \
    mvn -B -f docker-image-builds/maven-build-image/pom.xml -DskipTests dependency:go-offline

COPY src src
RUN --mount=type=cache,target=/root/.m2 \
    mvn -B -f docker-image-builds/maven-build-image/pom.xml -DskipTests package

FROM bellsoft/liberica-openjdk-25:jre-noble AS extract

WORKDIR /builder

COPY --from=build /workspace/docker-image-builds/maven-build-image/target/app.jar application.jar
RUN java -Djarmode=tools -jar application.jar extract --layers --destination extracted

FROM bellsoft/liberica-openjdk-25:jre-noble AS runtime

WORKDIR /application

RUN groupadd --system --gid 1001 app \
    && useradd --system --uid 1001 --gid app --home-dir /application --shell /usr/sbin/nologin app \
    && chown app:app /application

# The order follows BOOT-INF/layers.idx: dependencies change rarely, application
# classes change most often. This improves Docker layer cache reuse.
COPY --from=extract --chown=app:app /builder/extracted/dependencies/ ./
COPY --from=extract --chown=app:app /builder/extracted/spring-boot-loader/ ./
COPY --from=extract --chown=app:app /builder/extracted/snapshot-dependencies/ ./
COPY --from=extract --chown=app:app /builder/extracted/application/ ./

USER app

# Java 25 optimization: create an AOT cache in the image and enable it at launch.
RUN java -XX:AOTCacheOutput=app.aot -Dspring.context.exit=onRefresh -jar application.jar

EXPOSE 8080

ENTRYPOINT ["java", "-XX:AOTCache=app.aot", "-jar", "application.jar"]
