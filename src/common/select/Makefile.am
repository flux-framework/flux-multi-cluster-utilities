AM_CFLAGS = \
	$(WARNING_CFLAGS) \
	$(CODE_COVERAGE_CFLAGS)

AM_LDFLAGS = \
	$(CODE_COVERAGE_LIBS)

AM_CPPFLAGS = \
	-I$(top_srcdir) \
	$(FLUX_CORE_CFLAGS) \
	$(JANSSON_CFLAGS) \
	$(CODE_COVERAGE_CPPFLAGS)

noinst_LTLIBRARIES = libselect.la

libselect_la_SOURCES = \
	select.h \
	select_private.h \
	parser.c \
	select.c

libselect_la_LIBADD = \
	$(top_builddir)/src/common/libtomlc99/libtomlc99.la
