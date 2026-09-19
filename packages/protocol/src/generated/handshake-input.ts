/* Generated from schema/handshake-input.json; do not edit. */

export interface HandshakeInput {
  auth: HandshakeAuth;
  client: ClientInfo;
  protocol_version: string;
}
export interface HandshakeAuth {
  token: string;
}
export interface ClientInfo {
  kind: string;
  version: string;
}
