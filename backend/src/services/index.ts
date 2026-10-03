/**
 * Orchestration and policy.
 *
 * Empty. This is where the questions that are neither HTTP nor SQL get answered: what a device is
 * allowed to overwrite, whether a batch is a re-send or a new measurement, how a partial sync
 * resolves. A route must not decide these and a repository must not be asked.
 *
 * Nothing here touches `Env`'s bindings directly — a service is handed repositories.
 */
export {};
