FROM alpine:latest

LABEL "com.github.actions.name"="Auto-rebase and merge pull requests"
LABEL "com.github.actions.description"="Auto-rebase and merge pull requests if possible and rebase to master if they are behind"
LABEL "com.github.actions.icon"="git-merge"
LABEL "com.github.actions.color"="green"

LABEL version="1.0.0"
LABEL repository="http://github.com/afewyards/rebase-merge-after-checks-action"
LABEL homepage="http://github.com/afewyards/rebase-merge-after-checks-action"
LABEL maintainer="Thierry Kleist <thierry@kle.ist>"

RUN apk --no-cache add \
	bash \
  git \
	ca-certificates \
	coreutils \
	curl \
	jq

ADD entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]

