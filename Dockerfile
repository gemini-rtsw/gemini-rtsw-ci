FROM rockylinux:9

# Build arguments
ARG IN_PIPELINE=false
ARG PACKAGE_NAME

# Enable CRB (CodeReady Builder) and EPEL
RUN dnf install -y epel-release && \
    dnf install -y dnf-plugins-core && \
    dnf config-manager --set-enabled crb

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

# Copy custom setup script if it exists
COPY custom-repo-setup.sh* /tmp/

# Run custom setup script if it exists (to handle DNF distupgrade repository issues)
RUN if [ -f "/tmp/custom-repo-setup.sh" ]; then \
        echo "Found custom repo setup script, running it..." && \
        chmod +x /tmp/custom-repo-setup.sh && \
        cd /tmp && \
        ./custom-repo-setup.sh ; \
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
    rm -rf /var/cache/dnf /tmp/rpms /tmp/custom-repo-setup.sh /tmp/*.rpm

# Verify installation
CMD ["sh", "-c", "rpm -qa ${PACKAGE_NAME}"]
