# Umbraco CMS on Railway.
#
# Build context is the repository root, so paths below are repo-relative.

FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
ARG BUILD_CONFIGURATION=Release
ENV DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    DOTNET_NOLOGO=1
WORKDIR /src
COPY src/UmbracoCms.csproj ./
RUN dotnet restore UmbracoCms.csproj
COPY src/ ./
RUN dotnet publish UmbracoCms.csproj -c "$BUILD_CONFIGURATION" -o /app/publish /p:UseAppHost=false

FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS final
WORKDIR /app
COPY --from=build /app/publish ./

USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends gosu \
 && rm -rf /var/lib/apt/lists/* \
 && command -v gosu >/dev/null

# Pristine copies of every directory the backoffice can write to. The volume is mounted over
# the live paths at runtime, so the entrypoint restores the shipped defaults from here.
RUN mkdir -p /app/seed /app/wwwroot/css /app/wwwroot/scripts \
 && cp -r /app/Views /app/seed/Views \
 && cp -r /app/wwwroot/css /app/seed/css \
 && cp -r /app/wwwroot/scripts /app/seed/scripts

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh \
 && bash -n /usr/local/bin/entrypoint.sh

ENV DATA_DIR=/data \
    ASPNETCORE_HTTP_PORTS=8080 \
    Umbraco__CMS__Hosting__MachineIdentifier=railway

EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
