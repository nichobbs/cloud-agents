/** A rejected API call as `api` raises it: an Error carrying the HTTP status. */
export function httpError(status: number, message = `${status}`): Error & { status: number } {
  return Object.assign(new Error(message), { status });
}
