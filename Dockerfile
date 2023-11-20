FROM jenkins/inbound-agent:latest AS jenkins-agent


FROM buildpack-deps:jammy AS base

# set bash as the default interpreter for the build with:
# -e: exits on error, so we can use colon as line separator
# -u: throw error on variable unset
# -o pipefail: exits on first command failed in pipe
SHELL ["/bin/bash", "-euxo", "pipefail", "-c"]


# Build the init_as_root
FROM base AS init_as_root

# Install shc
RUN apt-get update; \
    apt-get install -y --no-install-recommends shc; \
    rm -rf /var/lib/apt/lists/*

COPY init_as_root.sh /
RUN shc -S -r -f /init_as_root.sh -o /init_as_root; \
    chown root:root /init_as_root; \
    chmod 4755 /init_as_root


FROM scratch AS rootfs

COPY --from=init_as_root /init_as_root /
COPY --from=jenkins-agent /usr/local/bin/jenkins-agent /usr/local/bin/jenkins-slave /usr/local/bin/
COPY --from=jenkins-agent /usr/share/jenkins /usr/share/jenkins
COPY --from=jenkins-agent /opt/java/openjdk /opt/java/openjdk
COPY rootfs /


FROM base

ENV NON_ROOT_USER="jenkins"
ARG HOME="/home/${NON_ROOT_USER}"

ENV AGENT_WORKDIR="${HOME}/agent"
ENV CI="true"
ENV EDITOR="nano"
ENV PATH="${HOME}/.local/bin:${PATH}:/opt/java/openjdk/bin"
## Locale and encoding
ENV LANG="en_US.UTF-8"
ENV LANGUAGE="en_US:en"
ENV LC_ALL="en_US.UTF-8"
ENV TZ="Etc/UTC"
## Entrypoint related
# Fails if cont-init and fix-attrs fails
ENV S6_BEHAVIOUR_IF_STAGE2_FAILS=2 
# Wait for services before running CMD 
ENV S6_CMD_WAIT_FOR_SERVICES=1 
# Give 15s for services to start 
ENV S6_CMD_WAIT_FOR_SERVICES_MAXTIME=15000 
# Give 15s for services to stop 
ENV S6_SERVICES_GRACETIME=15000 
# Honor container env on CMD 
ENV S6_KEEP_ENV=1

# create non-root user
RUN group="${NON_ROOT_USER}"; \
    uid="1000"; \
    gid="${uid}"; \
    groupadd -g "${gid}" "${group}"; \
    useradd -l -c "Jenkins user" -d "${HOME}" -u "${uid}" -g "${gid}" -m "${NON_ROOT_USER}" -s /bin/bash -p ""; \
    # install sudo and locales\
    apt_get="env DEBIANFRONTEND=noninteractive apt-get" ; \
    apt_get_install="${apt_get} install -yq --no-install-recommends"; \
    CURL="curl -fsSL"; \
    ${apt_get} update; \
    ${apt_get_install} \
        sudo \
        locales; \
    # setup locale \
    sed -i "/${LANG}/s/^# //g" /etc/locale.gen; \
    locale-gen; \
    # setup sudo \
    usermod -aG sudo "${NON_ROOT_USER}"; \
    echo "${NON_ROOT_USER}  ALL=(ALL) NOPASSWD:ALL" | tee "/etc/sudoers.d/${NON_ROOT_USER}"; \
    # dismiss sudo welcome message \
    sudo -u "${NON_ROOT_USER}" sudo true; \
    # create agent workdir \
    mkdir -p "${AGENT_WORKDIR}"; \
    chown -R "${NON_ROOT_USER}:${NON_ROOT_USER}" "${AGENT_WORKDIR}" ; \
    # add docker apt repo \
    install -m 0755 -d /etc/apt/keyrings; \
    ${CURL} https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg; \
    chmod a+r /etc/apt/keyrings/docker.gpg; \
    echo \
        "deb [arch="$(dpkg --print-architecture)" signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
        "$(. /etc/os-release && echo "${VERSION_CODENAME}")" stable" | \
        tee /etc/apt/sources.list.d/docker.list; \
    # install apt packages \
    ${apt_get} update; \
    ${apt_get_install} \
        # from https://github.com/jenkinsci/docker-agent/blob/de96775948b89697556993f829713f70af5e2f8a/debian/Dockerfile \
        ca-certificates \
        curl \
        fontconfig \
        git \
        git-lfs \
        less \
        netbase \
        openssh-client \
        patch \
        tzdata \
        # miscelaneous packages \
        wget \
        gnupg \
        tree \
        jq \
        parallel \
        rsync \
        sshpass \
        zip \
        unzip \
        xz-utils \
        time \
        # troubleshooting \
        net-tools \
        iputils-ping \
        traceroute \
        dnsutils \
        netcat \
        openssh-server \
        nano \
        # required for docker in docker \
        iptables \
        btrfs-progs \
        # docker \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin; \
    rm -rf /var/lib/apt/lists/*; \
    # setup docker \
    usermod -aG docker "${NON_ROOT_USER}"; \
    ## setup docker-switch (for docker-compose v1 compatibility) \
    version=$(basename "$(${CURL} -o /dev/null -w "%{url_effective}" https://github.com/docker/compose-switch/releases/latest)"); \
    ${CURL} --create-dirs -o "/usr/local/bin/docker-compose" "https://github.com/docker/compose-switch/releases/download/${version}/docker-compose-$(uname -s)-amd64"; \
    chmod +x /usr/local/bin/docker-compose; \
    ## dind \
    # set up subuid/subgid so that "--userns-remap=default" works out-of-the-box \
    addgroup --system dockremap; \
    adduser --system --ingroup dockremap dockremap; \
    echo 'dockremap:165536:65536' | tee -a /etc/subuid; \
    echo 'dockremap:165536:65536' | tee -a /etc/subgid; \
    # install dind hack \
    # https://github.com/moby/moby/commits/master/hack/dind \
    version="d58df1fc6c866447ce2cd129af10e5b507705624"; \
    ${CURL} -o /usr/local/bin/dind "https://raw.githubusercontent.com/moby/moby/${version}/hack/dind"; \
    chmod +x /usr/local/bin/dind; \
    # install retry \
    version=$(basename "$(${CURL} -o /dev/null -w "%{url_effective}" "https://github.com/kadwanev/retry/releases/latest")"); \
    ${CURL} "https://github.com/kadwanev/retry/releases/download/${version}/retry-${version}.tar.gz" \
        | tar -C /usr/local/bin -xzf - retry; \
    # install pkgx \
    version=$(basename "$(${CURL} -o /dev/null -w "%{url_effective}" "https://github.com/pkgxdev/pkgx/releases/latest")"); \
    ${CURL} "https://github.com/pkgxdev/pkgx/releases/download/${version}/pkgx-${version#v}+linux+$(uname -m | sed "s/_/-/g").tar.xz" \
        | tar -C /usr/local/bin -xJf - pkgx; \
    # install s6-overlay \
    version="3.1.6.2"; \
    ${CURL} "https://github.com/just-containers/s6-overlay/releases/download/v${version}/s6-overlay-noarch.tar.xz" \
        | tar -C / -Jxpf -; \
    ${CURL} "https://github.com/just-containers/s6-overlay/releases/download/v${version}/s6-overlay-x86_64.tar.xz" \
        | tar -C / -Jxpf -; \
    # fix sshd not starting \
    mkdir -p /run/sshd; \
    # install fixuid \
    # https://github.com/boxboat/fixuid/releases \
    version="0.6.0" ; \
    curl -fsSL "https://github.com/boxboat/fixuid/releases/download/v${version}/fixuid-${version}-linux-amd64.tar.gz" | tar -C /usr/local/bin -xzf -; \
    chown root:root /usr/local/bin/fixuid;\
    chmod 4755 /usr/local/bin/fixuid; \
    mkdir -p /etc/fixuid; \
    printf '%s\n' "user: ${NON_ROOT_USER}" "group: ${NON_ROOT_USER}" "paths:" "  - /" "  - ${AGENT_WORKDIR}" | tee /etc/fixuid/config.yml

USER "${NON_ROOT_USER}:${NON_ROOT_USER}"

WORKDIR "${AGENT_WORKDIR}"

VOLUME "${AGENT_WORKDIR}"

COPY --from=rootfs / /

ENTRYPOINT [ "/entrypoint.sh" ]
CMD [ "jenkins-agent" ]
