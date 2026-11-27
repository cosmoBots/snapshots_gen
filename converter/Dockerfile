# Runtime of the converter: a current Ruby, rubyzip and Redcarpet 3.5.1 (the
# Markdown parser of Redmine 4.2, to read links as the old instance did).
#   docker build -t snapshots_gen-converter converter/
FROM ruby:3.3
RUN gem install rubyzip -v 3.2.2 --no-document && gem install redcarpet -v 3.5.1 --no-document
WORKDIR /work
