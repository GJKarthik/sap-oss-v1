import { PetriNet, createPlace, createTransition, createArc, createToken } from './workflow.models';

export interface WorkflowTemplate {
  id: string;
  nameKey: string;
  descKey: string;
  icon: string;
  build: () => PetriNet;
}

function trainingPipeline(): PetriNet {
  const p1 = createPlace(80, 100, 'Raw Data', 'data');
  p1.tokens = [createToken('data', { file: 'train.csv' }), createToken('data', { file: 'val.csv' })];
  const t1 = createTransition(230, 100, 'Preprocess');
  const p2 = createPlace(380, 100, 'Clean Data', 'data');
  const t2 = createTransition(530, 100, 'Tokenize');
  const p3 = createPlace(680, 100, 'Tokenized', 'data');
  const t3 = createTransition(380, 250, 'Train Model');
  const p4 = createPlace(530, 250, 'Trained Model', 'resource');
  const t4 = createTransition(680, 250, 'Evaluate');
  const p5 = createPlace(830, 250, 'Results', 'control');
  return {
    id: 'tpl-train', name: 'Training Pipeline',
    places: [p1, p2, p3, p4, p5],
    transitions: [t1, t2, t3, t4],
    arcs: [
      createArc(p1.id, t1.id, 'place'), createArc(t1.id, p2.id, 'transition'),
      createArc(p2.id, t2.id, 'place'), createArc(t2.id, p3.id, 'transition'),
      createArc(p3.id, t3.id, 'place'), createArc(t3.id, p4.id, 'transition'),
      createArc(p4.id, t4.id, 'place'), createArc(t4.id, p5.id, 'transition'),
    ],
  };
}

function ocrBatch(): PetriNet {
  const pIn = createPlace(80, 150, 'PDF Queue', 'data');
  pIn.tokens = [createToken('data', { doc: 'invoice_01.pdf' }), createToken('data', { doc: 'contract.pdf' }), createToken('data', { doc: 'receipt.pdf' })];
  const tScan = createTransition(230, 150, 'OCR Scan');
  const pScanned = createPlace(380, 150, 'Scanned Text', 'data');
  const tExtract = createTransition(530, 80, 'Extract Fields');
  const pFields = createPlace(680, 80, 'Extracted Fields', 'data');
  const tValidate = createTransition(530, 220, 'Validate');
  const pValid = createPlace(680, 220, 'Validated', 'control');
  const pError = createPlace(380, 300, 'Errors', 'error');
  return {
    id: 'tpl-ocr', name: 'OCR Batch Processing',
    places: [pIn, pScanned, pFields, pValid, pError],
    transitions: [tScan, tExtract, tValidate],
    arcs: [
      createArc(pIn.id, tScan.id, 'place'), createArc(tScan.id, pScanned.id, 'transition'),
      createArc(pScanned.id, tExtract.id, 'place'), createArc(tExtract.id, pFields.id, 'transition'),
      createArc(pScanned.id, tValidate.id, 'place'), createArc(tValidate.id, pValid.id, 'transition'),
      createArc(tValidate.id, pError.id, 'transition'),
    ],
  };
}

function modelDeploy(): PetriNet {
  const pModel = createPlace(80, 120, 'Model Artifact', 'resource');
  pModel.tokens = [createToken('resource', { model: 'gemma-arabic-v2' })];
  const pConfig = createPlace(80, 260, 'Deploy Config', 'control');
  pConfig.tokens = [createToken('control', { replicas: 2 })];
  const tPackage = createTransition(250, 120, 'Package');
  const pImage = createPlace(420, 120, 'Container Image', 'resource');
  const tDeploy = createTransition(420, 190, 'Deploy');
  const pRunning = createPlace(590, 190, 'Running', 'control');
  const tHealth = createTransition(590, 290, 'Health Check');
  const pHealthy = createPlace(760, 290, 'Healthy', 'control');
  const pFailed = createPlace(420, 340, 'Failed', 'error');
  return {
    id: 'tpl-deploy', name: 'Model Deployment',
    places: [pModel, pConfig, pImage, pRunning, pHealthy, pFailed],
    transitions: [tPackage, tDeploy, tHealth],
    arcs: [
      createArc(pModel.id, tPackage.id, 'place'), createArc(tPackage.id, pImage.id, 'transition'),
      createArc(pImage.id, tDeploy.id, 'place'), createArc(pConfig.id, tDeploy.id, 'place'),
      createArc(tDeploy.id, pRunning.id, 'transition'),
      createArc(pRunning.id, tHealth.id, 'place'), createArc(tHealth.id, pHealthy.id, 'transition'),
      createArc(tHealth.id, pFailed.id, 'transition'),
    ],
  };
}

export const WORKFLOW_TEMPLATES: WorkflowTemplate[] = [
  { id: 'tpl-train', nameKey: 'workflow.tpl.training', descKey: 'workflow.tpl.trainingDesc', icon: 'process', build: trainingPipeline },
  { id: 'tpl-ocr', nameKey: 'workflow.tpl.ocr', descKey: 'workflow.tpl.ocrDesc', icon: 'document', build: ocrBatch },
  { id: 'tpl-deploy', nameKey: 'workflow.tpl.deploy', descKey: 'workflow.tpl.deployDesc', icon: 'machine', build: modelDeploy },
];
