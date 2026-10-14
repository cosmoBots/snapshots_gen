# Runtime of the converter: a current Ruby and rubyzip, nothing else.
#   docker build -t snapshots_gen-converter converter/
FROM ruby:3.3
RUN gem install rubyzip -v 3.2.2 --no-document
WORKDIR /work
