# EL (Rocky) major version. Default 8 so existing callers are unchanged.
ARG EL_VERSION=8
FROM rockylinux:${EL_VERSION}

# Build arguments (ARGs before FROM are out of scope after it; redeclare)
ARG EL_VERSION=8
ARG IN_PIPELINE=false
ARG PACKAGE_NAME

# Enable EPEL + the CodeReady Builder repo. EL8 calls it "powertools", EL9 "crb".
RUN dnf install -y epel-release && \
    dnf install -y dnf-plugins-core && \
    if [ "${EL_VERSION}" = "9" ]; then \
        dnf config-manager --set-enabled crb ; \
    else \
        dnf config-manager --set-enabled powertools ; \
    fi

# Install base development tools and dependencies
RUN dnf install -y gcc-c++ \
    make \
    cmake \
    git \
    rpm-build \
    rpmdevtools \
    conserver \
    conserver-client

# Configure RPM repository (served by rpm-repo container on Docker network)
RUN echo -e "\n\
[rpm-repo]\n\
name=RPM Repository\n\
baseurl=http://rpm-repo:8080/rpm-repo/\n\
enabled=1\n\
gpgcheck=0\n\
" > /etc/yum.repos.d/rpm-repo.repo && \
    dnf makecache --refresh

# Create directory for RPMs
RUN mkdir -p /tmp/rpms/

# Copy RPMs if they exist
COPY rpms/ /tmp/rpms/

# Copy custom setup script directory (may be empty)
COPY .custom-scripts/ /tmp/custom-scripts/

# Run custom setup script if it exists
RUN if [ -f "/tmp/custom-scripts/custom-repo-setup.sh" ]; then \
        echo "Found custom repo setup script, running it..." && \
        chmod +x /tmp/custom-scripts/custom-repo-setup.sh && \
        cd /tmp && \
        ./custom-scripts/custom-repo-setup.sh ; \
    else \
        echo "No custom setup script found, proceeding normally..." ; \
    fi

# Install local RPM if available, otherwise from repo
RUN if [ "$(ls -A /tmp/rpms/ 2>/dev/null)" ]; then \
        echo "Found RPMs in /tmp/rpms, installing locally" && \
        if ls /tmp/rpms/*-devel*.rpm 1> /dev/null 2>&1; then \
            dnf install -y /tmp/rpms/*-devel*.rpm /tmp/rpms/*.rpm ; \
        else \
            dnf install -y /tmp/rpms/*.rpm ; \
        fi \
    else \
        echo "No RPMs found in /tmp/rpms, falling back to repo install" && \
        if dnf list ${PACKAGE_NAME}-devel &>/dev/null; then \
            dnf install -y ${PACKAGE_NAME}-devel ${PACKAGE_NAME} ; \
        else \
            dnf install -y ${PACKAGE_NAME} ; \
        fi \
    fi

# Cleanup
RUN dnf clean all && \
    rm -rf /var/cache/dnf /tmp/rpms /tmp/custom-scripts /tmp/*.rpm

# Verify installation
CMD ["sh", "-c", "rpm -qa ${PACKAGE_NAME}"]
