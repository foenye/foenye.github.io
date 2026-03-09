.PHONY: publish
publish:
	rm -rf resources;hugo --buildDrafts; git add .; git commit -m w; git push origin HEAD