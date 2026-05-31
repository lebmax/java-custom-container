FROM maven:3.9.16-eclipse-temurin-25 AS build

RUN mkdir /usr/src/project
COPY . /usr/src/project
WORKDIR /usr/src/project

RUN mvn package -DskipTests
RUN jdeps --ignore-missing-deps -q  \
    --recursive  \
    --multi-release 25  \
    --print-module-deps  \
    --class-path 'BOOT-INF/lib/*'  \
    target/app.jar > deps.info

RUN jlink \
    --add-modules $(cat deps.info) \
    --strip-debug \
    --compress zip-9 \
    --no-header-files \
    --no-man-pages \
    --output /myjre

FROM cr.int.axiomjdk.ru/axiom-linux-25/axiom-linux-base:25-musl

ENV JAVA_HOME /user/java/jdk25
ENV PATH $JAVA_HOME/bin:$PATH
COPY --from=build /myjre $JAVA_HOME

RUN mkdir /app

COPY --from=build /usr/src/project/target/app.jar /app/
WORKDIR /app

ENTRYPOINT ["java", "-jar", "app.jar"]
