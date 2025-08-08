FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Install runtime dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        && rm -rf /var/lib/apt/lists/*

# Create envoy user
RUN adduser --group --system envoy

# Copy the custom Envoy binary
COPY envoy-static /usr/local/bin/envoy

# Copy entrypoint script (from the official repo)
COPY docker-entrypoint-simple.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

# Create config directory
RUN mkdir -p /etc/envoy && chown envoy:envoy /etc/envoy

# Set permissions
RUN chmod +x /usr/local/bin/envoy

# Expose ports
EXPOSE 10443 9901

# Set entrypoint
ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["envoy", "-c", "/etc/envoy/envoy.yaml"]
