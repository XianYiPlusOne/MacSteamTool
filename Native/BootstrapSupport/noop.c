/* Retired compatibility source.  Intel slices must be compiled from the real
 * extension sources; keeping this file build-failing prevents a legacy recipe
 * from silently reintroducing a universal no-op binary. */
#error "The Intel bootstrap no-op slice was retired; use the architecture-aware build scripts"
