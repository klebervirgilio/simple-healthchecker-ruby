FROM ruby:2.4.1

RUN apt-get update \
    && apt-get install telnet

RUN mkdir /app
WORKDIR /app
ADD Gemfile /app/Gemfile
ADD Gemfile.lock /app/Gemfile.lock
RUN bundle install
