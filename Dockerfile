FROM debian:bookworm-slim AS luajit-builder

RUN apt-get update -qq && apt-get install -y -qq \
    build-essential \
    git \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN git clone --depth 1 https://github.com/LuaJIT/LuaJIT.git .
RUN make -j$(nproc) && make install PREFIX=/usr

FROM debian:bookworm-slim AS builder

ARG LUANTI_VERSION=5.16.1

RUN apt-get update -qq && apt-get install -y -qq \
    build-essential \
    cmake \
    git \
    libcurl4-openssl-dev \
    libgmp-dev \
    libjsoncpp-dev \
    libncurses-dev \
    libsqlite3-dev \
    pkg-config \
    zlib1g-dev \
    libzstd-dev \
  && rm -rf /var/lib/apt/lists/*

COPY --from=luajit-builder /usr/lib/libluajit-5.1.so* /usr/lib/
COPY --from=luajit-builder /usr/include/luajit-2.1/ /usr/include/luajit-2.1/
COPY --from=luajit-builder /usr/bin/luajit /usr/bin/luajit

WORKDIR /src
RUN git clone --depth 1 --branch ${LUANTI_VERSION} \
    https://github.com/luanti-org/luanti.git .

RUN mkdir build && cd build && \
    cmake .. \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SERVER=ON \
    -DBUILD_CLIENT=OFF \
    -DBUILD_UNITTESTS=OFF \
    -DBUILD_BENCHMARKS=OFF \
    -DBUILD_DOCUMENTATION=OFF \
    -DENABLE_CURL=ON \
    -DENABLE_LUAJIT=ON \
    -DENABLE_SYSTEM_GMP=ON \
    -DENABLE_SYSTEM_JSONCPP=ON \
    -DENABLE_CURSES=ON \
    -DENABLE_OPENSSL=ON \
    -DENABLE_GETTEXT=OFF \
    -DENABLE_SOUND=OFF \
    -DENABLE_UPDATE_CHECKER=OFF \
    -DRUN_IN_PLACE=OFF \
    -DCMAKE_INSTALL_PREFIX=/usr \
    && make -j$(nproc) \
    && make install

FROM debian:bookworm-slim

ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8
ENV TERM=xterm-256color

RUN apt-get update -qq && apt-get install -y -qq \
    ca-certificates \
    libcurl4 \
    libgmp10 \
    libjsoncpp25 \
    libncursesw6 \
    libsqlite3-0 \
    locales \
    zlib1g \
    libzstd1 \
  && sed -i '/en_US.UTF-8/s/^# //' /etc/locale.gen \
  && locale-gen \
  && rm -rf /var/lib/apt/lists/*

COPY --from=builder /usr/bin/luantiserver /usr/bin/luantiserver
COPY --from=builder /usr/share/luanti/ /usr/share/luanti/
COPY --from=luajit-builder /usr/lib/libluajit-5.1.so* /usr/lib/
COPY --from=luajit-builder /usr/bin/luajit /usr/bin/luajit

RUN groupadd -g 1000 luanti && useradd -u 1000 -g luanti -d /config/.minetest -s /bin/sh luanti

USER luanti
WORKDIR /config/.minetest

EXPOSE 30000/udp

ENTRYPOINT ["luantiserver"]
CMD ["--help"]
