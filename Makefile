
DATADIR = /usr/share/rsget.pl
BINDIR = /usr/bin
VER =
PKGDIR = rsget.pl-$(VER)

PLUGIN_DIRS = Get Link Video
DIRS = RSGet,Get,Link,Video,data

all: rsget.pl

ifeq ($(VER),)
pkg:
	make VER="$$(svn up | sed '/At revision /!d; s/At revision //; s/\.//')" pkg
else
pkg: clean
	rm -rf $(PKGDIR)
	install -d $(PKGDIR)/{$(DIRS)}
	install rsget.pl $(PKGDIR)
	cp Makefile README README.config README.requirements $(PKGDIR)
	cp RSGet/*.pm $(PKGDIR)/RSGet
	for DIR in $(PLUGIN_DIRS); do \
		cp $$DIR/* $(PKGDIR)/$$DIR || exit 1; \
		cp $$DIR/.template $(PKGDIR)/$$DIR || exit 1; \
	done
	cp data/* $(PKGDIR)/data
	tar -cjf $(PKGDIR).tar.bz2 $(PKGDIR)
endif

install: clean
	install -d $(DESTDIR)$(DATADIR)/{$(DIRS)} $(DESTDIR)$(BINDIR)
	sed 's#\($$install_path\) =.*;#\1 = "$(DATADIR)";#' < rsget.pl > rsget.pl.datadir
	install rsget.pl.datadir $(DESTDIR)$(BINDIR)/rsget.pl
	cp RSGet/*.pm $(DESTDIR)$(DATADIR)/RSGet
	cp data/* $(DESTDIR)$(DATADIR)/data
	for DIR in $(PLUGIN_DIRS); do \
		cp $$DIR/* $(DESTDIR)$(DATADIR)/$$DIR || exit 1; \
	done
	grep -l "status:\s*BROKEN" $(DESTDIR)$(DATADIR)/{Get,Link,Video}/* | xargs -r rm -v

.PHONY: clean
clean:
	rm -fv {$(DIRS),.}/*~
	rm -fv {$(DIRS),.}/svn-commit.tmp*
	rm -fv rsget.pl.datadir
