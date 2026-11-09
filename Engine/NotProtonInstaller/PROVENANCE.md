NotProton installation adapter

Adapted from https://github.com/NotProtonNot/NotProton (local source revision recorded below), GPL-3.0; license in ../../Licenses/NotProton.txt.

Changes: command-line entry, resource bundle selected from the installed official companion, structured progress, refusal to stop running Steam, preserving macSteam / CloudRedirect / other DYLD inserts, and backup/rollback wrapper. No CrossOver, Wine or NotProton runtime binary is included here.

0.2.13 adds guarded replacement of the installed 1.2.3 kernel with Fluent's
WebUI route-capacity repair, including receipt validation and isolated
install/rollback tests. The separately bundled kernel source patch and build are
documented in ../../Native/NotProton/PROVENANCE.md. Other versions are refused;
this repair does not install or replace runners, profiles or game prefixes.
692b470e73d0d497ee9e474038efda819a037772
