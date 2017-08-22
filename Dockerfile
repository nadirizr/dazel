FROM debian:jessie-backports
MAINTAINER Nadir Izrael nadir.izr@gmail.com

ENV BAZEL_VERSION 0.5.3

RUN echo 'APT::Install-Recommends "false";' >> /etc/apt/apt.conf.d/99_norecommends \
 && echo 'APT::AutoRemove::RecommendsImportant "false";' >> /etc/apt/apt.conf.d/99_norecommends \
 && echo 'APT::AutoRemove::SuggestsImportant "false";' >> /etc/apt/apt.conf.d/99_norecommends

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && echo "deb [arch=amd64] http://storage.googleapis.com/bazel-apt stable jdk1.8" > \
         /etc/apt/sources.list.d/bazel.list \
 && curl https://storage.googleapis.com/bazel-apt/doc/apt-key.pub.gpg | apt-key add - \
 && apt-get update \
 && apt-get install -y -t jessie-backports openjdk-8-jdk \
 && apt-get install -y --no-install-recommends bazel=${BAZEL_VERSION} \
 && apt-get purge --auto-remove -y curl \
 && rm -rf /etc/apt/sources.list.d/bazel.list \
 && rm -rf /var/lib/apt/lists/*

RUN update-ca-certificates -f

