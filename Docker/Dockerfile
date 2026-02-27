FROM raspbian/stretch

RUN echo 'deb http://archive.raspberrypi.org/debian/ stretch main' > /etc/apt/sources.list && \
    echo 'deb http://legacy.raspbian.org/raspbian stretch main contrib non-free rpi firmware' >> /etc/apt/sources.list && \
    echo 'deb-src http://legacy.raspbian.org/raspbian stretch main contrib non-free rpi firmware' >> /etc/apt/sources.list

# Add [trusted=yes] to disable the GPG check temporarily for snapshot repositories
RUN sed -i 's/^deb /deb [trusted=yes] /' /etc/apt/sources.list
RUN sed -i 's/^deb-src /deb-src [trusted=yes] /' /etc/apt/sources.list

RUN apt-get -o Acquire::Check-Valid-Until=false update -y -q

# Skip apt-get upgrade: causes systemd segfault in ARM32 container on ARM64 host
# Install only what we need
RUN apt install --fix-missing --fix-broken -y -q --allow-unauthenticated \
    multiarch-support libavformat57 libportaudio2* libflac++6v5* \
    libavahi-common3 libavahi-client3 alsa-utils curl tmux

# PulseAudio client libs for routing audio through PipeWire on host
RUN apt install -y -q --allow-unauthenticated libpulse0 libasound2-plugins

#libcurl3 -y
RUN mkdir -p /app/tidal-connect
WORKDIR /app/tidal-connect

RUN curl -k -O -L https://snapshot.debian.org/archive/debian-security/20190925T215334Z/pool/updates/main/o/openssl/libssl1.0.0_1.0.1t-1%2Bdeb8u12_armhf.deb
RUN apt install -y ./libssl1.0.0_1.0.1t-1%2Bdeb8u12_armhf.deb
RUN rm ./libssl1.0.0_1.0.1t-1%2Bdeb8u12_armhf.deb

RUN curl -k -O -L https://snapshot.debian.org/archive/debian-security/20190913T112238Z/pool/updates/main/c/curl/libcurl3_7.38.0-4%2Bdeb8u16_armhf.deb
RUN apt install -y ./libcurl3_7.38.0-4%2Bdeb8u16_armhf.deb --allow-downgrades
RUN rm ./libcurl3_7.38.0-4%2Bdeb8u16_armhf.deb

# Binaries and certificate are stored compressed; decompress at build time
COPY Docker/src/bin/ bin/
RUN gunzip bin/*.gz && chmod a+x bin/*
COPY Docker/src/pa_devs/ .
COPY Docker/src/play .
COPY Docker/src/id_certificate id_certificate/
RUN gunzip id_certificate/*.gz
COPY Docker/src/licenses licenses

# Route ALSA through PulseAudio (-> PipeWire on host via socket)
RUN printf 'pcm.!default {\n    type pulse\n}\nctl.!default {\n    type pulse\n}\n' > /etc/asound.conf

ENV PA_ALSA_PLUGHW=1
# PULSE_SERVER is set via docker-compose.yml environment, not hardcoded here

COPY Docker/entrypoint.sh /
RUN chmod a+x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]

