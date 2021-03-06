#!/usr/bin/make -f

#-----------------------------------------------------------------------------

ifeq ($(wildcard .*.plt),)
#DIALYZER_PLT = ~/.dialyzer_plt
else
DIALYZER_PLT = ~/.dialyzer_plt $(wildcard .*.plt)
endif
DIALYZER_OPTS = --no_check_plt $(if $(DIALYZER_PLT),--plts $(DIALYZER_PLT))

DIAGRAMS = $(basename $(notdir $(wildcard diagrams/*.diag)))
DIAGRAMS_SVG = $(foreach D,$(DIAGRAMS),doc/images/$D.svg)

#-----------------------------------------------------------------------------

PROJECT = harpcaller
APP_VERSION = $(call app-version,ebin/$(PROJECT).app)
ERL_INSTALL_LIB_DIR = $(ERL_LIB_DIR)/$(PROJECT)-$(APP_VERSION)
DOCDIR = /usr/share/doc/harpcaller
MANDIR = /usr/share/man
CONFDIR = /etc/harpcaller
ESCRIPT_ARGS_FILE = $(CONFDIR)/erlang.args

ERLC_OPTS = +debug_info
EDOC_OPTS := {overview, "src/overview.edoc"}, \
             {source_path, ["src", "examples"]}, \
             todo
ifneq ($(devel),)
EDOC_OPTS := $(EDOC_OPTS), private
endif

include erlang.mk
include erlang.install.mk

src/harp_json_lexer.erl::
	$(verbose)if ! grep -q @private $@; then echo '%%% @private' > $@.erl_gen_tmp; cat $@ >> $@.erl_gen_tmp; cat $@.erl_gen_tmp > $@; rm -f $@.erl_gen_tmp; fi

#-----------------------------------------------------------------------------

.PHONY: dialyzer
YECC_ERL_FILES = $(subst .yrl,.erl,$(subst .xrl,.erl,$(wildcard src/*.[xy]rl)))
ERL_SOURCE_FILES = $(filter-out $(YECC_ERL_FILES),$(wildcard src/*.erl))
dialyzer:
	@echo "dialyzer $(strip $(DIALYZER_OPTS)) --src src/*.erl"
	@dialyzer $(strip $(DIALYZER_OPTS)) --src $(ERL_SOURCE_FILES)

#-----------------------------------------------------------------------------

.PHONY: doc
doc: diagrams edoc

.PHONY: diagrams
diagrams: $(DIAGRAMS_SVG)

doc/images/%.svg: diagrams/%.diag
	blockdiag -o $@ -T svg $<

#-----------------------------------------------------------------------------

.PHONY: install install-erlang install-doc

install: install-erlang

install-erlang: app
	$(call install-wildcard,644,ebin/*,$(DESTDIR)$(ERL_INSTALL_LIB_DIR)/ebin)
	$(call install-escript,bin/harpcallerd,$(DESTDIR)/usr/sbin/harpcallerd,-noinput -kernel error_logger silent -args_file $(ESCRIPT_ARGS_FILE))
	mkdir -p $(DESTDIR)$(CONFDIR)
	touch $(DESTDIR)$(ESCRIPT_ARGS_FILE)
	install -m 644 examples/harpcaller.toml $(DESTDIR)$(CONFDIR)/harpcaller.toml.example

install-doc: doc
	$(call install-wildcard,644,doc/*.html doc/*.png doc/*.css,$(DESTDIR)$(DOCDIR)/erlang-api)
	$(call install-wildcard,644,doc/images/*.svg,$(DESTDIR)$(DOCDIR)/erlang-api/images)

#-----------------------------------------------------------------------------
# vim:ft=make
