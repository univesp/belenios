FROM glondu/beleniosbase:20260106-1

# Copy source
ADD --chown=belenios . /home/belenios/

# Build
WORKDIR /home/belenios

# Fix carriage returns in shell scripts
RUN find . -type f -name "*.sh" -exec sed -i 's/\r$//' {} \; \
    && find . -type f -name "*.sh" -exec chmod +x {} \;

# Fix specific build inputs known to cause issues if CRLF
RUN find po -type f -name "LINGUAS" -exec sed -i 's/\r$//' {} \; \
    && sed -i 's/\r$//' VERSION

# Patch Makefile to skip 'clean' step to avoid segmentation faults in dune clean
# We replace $(MAKE) clean with a comment or echo
RUN sed -i 's/\$(MAKE) clean/@echo "Skipping make clean"/' Makefile

# Run build
RUN . /home/belenios/.belenios/env.sh \
    && make build-release-server

# Cloud Run Entrypoint
COPY --chown=belenios cloudrun/entrypoint.sh /home/belenios/cloudrun/entrypoint.sh
COPY --chown=belenios cloudrun/ocsigenserver.conf.in /home/belenios/cloudrun/ocsigenserver.conf.in
RUN sed -i 's/\r$//' /home/belenios/cloudrun/entrypoint.sh \
    && chmod +x /home/belenios/cloudrun/entrypoint.sh

# Install SSH client for tunneling
USER root
RUN apt-get update && apt-get install -y \
    openssh-client \
    libgd-securityimage-perl \
    && rm -rf /var/lib/apt/lists/*
USER belenios


# Entrypoint
ENTRYPOINT ["/home/belenios/cloudrun/entrypoint.sh"]
