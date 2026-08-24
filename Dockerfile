FROM maven:3.9.16-eclipse-temurin-25 AS build

WORKDIR /app

# Copy Maven files
COPY pom.xml .

# Download dependencies
RUN mvn dependency:go-offline -B

# Copy source code
COPY src src

# Build the application
RUN mvn package -DskipTests

FROM cr.yandex/crpgua9ba7h8red2hulb/25-trusted-axiom-runtime-container-pro:jre-25-glibc

WORKDIR /app

ENV LANG=ru_RU.UTF-8
ENV LC_ALL=ru_RU.UTF-8

# Copy the built JAR from the build stage
COPY --from=build /app/target/*.jar app.jar

USER 65534:65534

ENTRYPOINT ["java", "-jar", "app.jar"]
