declare class InvalidSimilaritySearchAlgoNameError extends Error {
  code: number;
  constructor(message: string, code: number);
}
export = InvalidSimilaritySearchAlgoNameError;
