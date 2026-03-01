/**
 * Representation of the 'MetaData' schema.
 */
export type MetaData = {
    /**
     * @example "destination-name"
     */
    destination?: string;
    /**
     * @example [
     *   {
     *     "key": "purpose",
     *     "value": [
     *       "demonstration"
     *     ]
     *   },
     *   {
     *     "key": "sample-key",
     *     "value": [
     *       "sample-value1",
     *       "sample-value2"
     *     ]
     *   }
     * ]
     */
    dataRepositoryMetadata?: ({
        /**
         * Max Length: 1024.
         * Min Length: 1.
         */
        key: string;
        /**
         * Min Items: 1.
         */
        value: string[];
    } & Record<string, any>)[];
} & Record<string, any>;
//# sourceMappingURL=meta-data.d.ts.map