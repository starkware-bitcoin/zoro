# Zcash consensus in Cairo

This package is a Cairo library providing primitives for validating Zcash consensus.  

It is structured as follows:
* `types` module contains all Zcash specific entities (start your codebase tour with this folder) adapted for recursive verification;
* `validation` module contains most of the consensus validation logic;
