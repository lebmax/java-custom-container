FROM maven:3.9.16-eclipse-temurin-25 AS build

WORKDIR /usr/src/project

COPY pom.xml .
RUN mvn dependency:go-offline -B

COPY src src
RUN mvn package -DskipTests

RUN mkdir -p target/deps && \
    cd target/deps && \
    jar -xf ../app.jar

RUN jdeps --ignore-missing-deps -q  \
    --recursive  \
    --multi-release 25  \
    --print-module-deps  \
    --class-path 'target/deps/BOOT-INF/lib/*'  \
    target/deps/BOOT-INF/classes > deps.info

RUN jlink \
    --add-modules "$(cat deps.info)" \
    --strip-debug \
    --compress zip-9 \
    --no-header-files \
    --no-man-pages \
    --output /myjre

FROM cr.int.axiomjdk.ru/axiom-linux-25/axiom-linux-base:25-glibc

ENV JAVA_HOME=/user/java/jdk25
ENV PATH="${JAVA_HOME}/bin:${PATH}"

COPY --from=build /myjre $JAVA_HOME

RUN mkdir /app

COPY --from=build --chown=10001:10001 /usr/src/project/target/app.jar /app/
WORKDIR /app
USER 10001:10001

EXPOSE 8080

ENTRYPOINT ["java", "-jar", "app.jar"]
