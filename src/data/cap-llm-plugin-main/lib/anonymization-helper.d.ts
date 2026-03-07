/** Map of element names to their @anonymize annotation parameter values. */
export interface AnonymizedElements {
    [elementName: string]: string;
}
/** Known SAP HANA Cloud anonymization algorithm type. */
export type AnonymizeAlgorithm = string;
export declare function createAnonymizedView(schemaName: string, entityName: string, anonymizeAlgorithm: AnonymizeAlgorithm, anonymizedElements: AnonymizedElements): Promise<void>;
//# sourceMappingURL=anonymization-helper.d.ts.map