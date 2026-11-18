// The Dispatch profile uses an ellipsoid, raster imagery and observation/stop
// primitives. It never accepts compressed model or terrain assets. Cesium's
// aggregate meshoptimizer import eagerly initializes five Wasm modules even
// when those formats are unused, violating this page's script-src 'self'.
// Fail on demand without enabling code generation or changing global APIs.
const unavailable = () => { throw new Error("Compressed mesh assets are unavailable in the Dispatch observation profile."); };

export const MeshoptDecoder = Object.freeze({
  supported: false,
  get ready() { return Promise.reject(new Error("Compressed mesh assets are unavailable in the Dispatch observation profile.")); },
  useWorkers: unavailable,
  decodeVertexBuffer: unavailable,
  decodeIndexBuffer: unavailable,
  decodeIndexSequence: unavailable,
  decodeGltfBuffer: unavailable,
  decodeGltfBufferAsync: async () => unavailable()
});
