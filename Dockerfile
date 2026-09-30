FROM ubuntu:latest
LABEL authors="todaisy"

ENTRYPOINT ["top", "-b"]