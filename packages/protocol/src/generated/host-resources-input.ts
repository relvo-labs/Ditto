/* Generated from schema/host-resources-input.json; do not edit. */

/**
 * Node heap figures. Three separate numbers: never summed with each other
 * or with the process PSS Core reads from `/proc` (NFR-15).
 */
export interface ResourcesInput {
  array_buffers: number;
  external: number;
  heap_used: number;
}
