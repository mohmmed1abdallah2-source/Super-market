FROM dart:stable AS build
WORKDIR /src/server
COPY server/pubspec.yaml server/pubspec.lock* ./
RUN dart pub get
COPY server/ ./
RUN dart compile exe bin/server.dart -o /out/supermarket-erp-server

FROM dart:stable
WORKDIR /app
COPY --from=build /out/supermarket-erp-server /app/supermarket-erp-server
EXPOSE 8080
ENV ERP_HOST=0.0.0.0
ENV PORT=8080
ENTRYPOINT ["/app/supermarket-erp-server"]
