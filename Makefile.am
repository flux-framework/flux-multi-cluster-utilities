.NOTPARALLEL:

SUBDIRS = . src

EXTRA_DIST = \
	README.md

ACLOCAL_AMFLAGS = -I config

# coverage

CODE_COVERAGE_IGNORE_PATTERN = \
	"$(abs_top_builddir)/t/*" \
	"*/test/*.c" \
	"*/tests/*.c" \
	"*/man3/*.c" \
	"*/libtap/*" \
	"*/libev/*" \
	"/usr/include/*" \
	"/usr/lib*"

CODE_COVERAGE_LCOV_OPTIONS =
@CODE_COVERAGE_RULES@

# Many of flux-core's tests live down in subdirectories with
# the core that that it is testing.  However, some of those tests
# also have dependencies on other subdirectories higher up the
# source tree.  With the recursive Makefiles approach, there is
# no easy way to express that build dependency in a way that will
# actually trigger the build of the that dependency.  The following
# check-local rule, in conjunction with putting "." _first_ in this
# file's SUBDIRS, ensures that "all" is built before any of the
# recursive checks.
check-local: all
if ENABLE_PYLINT
	$(top_srcdir)/scripts/pylint
endif

check-prep: all
	cd src && $(MAKE) check
	cd doc && $(MAKE) check
	cd t && $(MAKE) check-prep
