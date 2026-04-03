import { HttpClient } from '@angular/common/http';
import { Component, OnInit } from '@angular/core';
import { LiveDemoHealthService } from '../../core/live-demo-health.service';
import { environment } from '../../../environments/environment';

interface OcrDocumentResponse {
  id?: string;
  extraction?: {
    original_ar?: string;
    translated_en?: string;
    financial_fields?: Array<{ key?: string; value?: string; confidence?: number }>;
    line_items?: Array<{ description_ar?: string; description_en?: string; quantity?: number; unit_price?: number; total?: number }>;
  };
}

interface OcrDocumentListResponse {
  data?: Array<{ id?: string; file_name?: string; created_at?: number }>;
}

@Component({
  selector: 'playground-ocr-page',
  templateUrl: './ocr-page.component.html',
  styleUrls: ['./ocr-page.component.scss'],
  standalone: false,
})
export class OcrPageComponent implements OnInit {
  documentText = '';
  language = 'ar';
  isDragOver = false;
  selectedFileName = '';
  selectedFileMimeType = '';
  selectedFileBase64 = '';
  filePreviewType: 'image' | 'pdf' | 'text' | 'generic' | '' = '';
  filePreviewUrl = '';
  filePreviewTextSnippet = '';
  loading = false;
  loadingHistory = false;
  routeBlocked = false;
  blockingReason = '';
  lastError: string | null = null;
  result: OcrDocumentResponse['extraction'] | null = null;
  recentDocuments: Array<{ id: string; label: string }> = [];

  constructor(
    private readonly http: HttpClient,
    private readonly healthService: LiveDemoHealthService,
  ) {}

  ngOnInit(): void {
    this.healthService.checkRouteReadiness('ocr').subscribe((readiness) => {
      this.routeBlocked = readiness.blocking;
      const failed = readiness.checks.find((check) => !check.ok);
      this.blockingReason = failed
        ? `Live service required: ${failed.name} (${failed.status || 'no status'})`
        : '';
      if (!this.routeBlocked) {
        this.loadRecentDocuments();
      }
    });
  }

  processDocument(): void {
    if (this.routeBlocked || this.loading) {
      return;
    }
    this.loading = true;
    this.lastError = null;
    const endpoint = `${environment.openAiBaseUrl.replace(/\/$/, '')}/v1/ocr/documents`;
    this.http.post<OcrDocumentResponse>(endpoint, {
      text: this.documentText,
      language: this.language,
      document_type: 'invoice',
      file_name: this.selectedFileName || `invoice-${Date.now()}.txt`,
      mime_type: this.selectedFileMimeType || undefined,
      file_content_base64: this.selectedFileBase64 || undefined,
    }).subscribe({
      next: (response) => {
        this.result = response.extraction || null;
        this.loading = false;
        this.loadRecentDocuments();
      },
      error: (error: { message?: string }) => {
        this.lastError = error?.message ?? 'Failed to process OCR document';
        this.loading = false;
      },
    });
  }

  async onFileSelected(event: Event): Promise<void> {
    const file = (event.target as HTMLInputElement)?.files?.[0];
    if (!file) {
      return;
    }
    await this.processDroppedFile(file);
  }

  clearSelectedFile(): void {
    this.selectedFileName = '';
    this.selectedFileMimeType = '';
    this.selectedFileBase64 = '';
    this.filePreviewType = '';
    this.filePreviewUrl = '';
    this.filePreviewTextSnippet = '';
  }

  onDragOver(event: DragEvent): void {
    event.preventDefault();
    this.isDragOver = true;
  }

  onDragLeave(event: DragEvent): void {
    event.preventDefault();
    this.isDragOver = false;
  }

  async onDrop(event: DragEvent): Promise<void> {
    event.preventDefault();
    this.isDragOver = false;
    const file = event.dataTransfer?.files?.[0];
    if (!file) {
      return;
    }
    await this.processDroppedFile(file);
  }

  loadRecentDocuments(): void {
    if (this.routeBlocked || this.loadingHistory) {
      return;
    }
    this.loadingHistory = true;
    const endpoint = `${environment.openAiBaseUrl.replace(/\/$/, '')}/v1/ocr/documents`;
    this.http.get<OcrDocumentListResponse>(endpoint).subscribe({
      next: (response) => {
        const list = response?.data ?? [];
        this.recentDocuments = list
          .map((item) => {
            const id = item.id?.trim();
            if (!id) return null;
            return {
              id,
              label: item.file_name?.trim() || id,
            };
          })
          .filter((item): item is { id: string; label: string } => item !== null);
        this.loadingHistory = false;
      },
      error: () => {
        this.loadingHistory = false;
      },
    });
  }

  loadDocument(documentId: string): void {
    if (!documentId || this.routeBlocked) {
      return;
    }
    this.lastError = null;
    const endpoint = `${environment.openAiBaseUrl.replace(/\/$/, '')}/v1/ocr/documents/${encodeURIComponent(documentId)}`;
    this.http.get<OcrDocumentResponse>(endpoint).subscribe({
      next: (response) => {
        this.result = response.extraction || null;
      },
      error: (error: { message?: string }) => {
        this.lastError = error?.message ?? 'Failed to load OCR document';
      },
    });
  }

  private toBase64(buffer: ArrayBuffer): string {
    let binary = '';
    const bytes = new Uint8Array(buffer);
    for (let i = 0; i < bytes.byteLength; i++) {
      binary += String.fromCharCode(bytes[i]);
    }
    return btoa(binary);
  }

  private async processDroppedFile(file: File): Promise<void> {
    this.selectedFileName = file.name;
    this.selectedFileMimeType = file.type || 'application/octet-stream';
    const arrayBuffer = await this.readFileAsArrayBuffer(file);
    this.selectedFileBase64 = this.toBase64(arrayBuffer);
    this.setFilePreview(file, arrayBuffer);
    const extension = file.name.split('.').pop()?.toLowerCase();
    if (this.selectedFileMimeType.startsWith('text/') || extension === 'txt') {
      this.documentText = await this.readFileAsText(file);
      this.filePreviewTextSnippet = this.documentText.slice(0, 400);
    }
  }

  private setFilePreview(file: File, arrayBuffer: ArrayBuffer): void {
    this.filePreviewType = 'generic';
    this.filePreviewUrl = '';
    this.filePreviewTextSnippet = '';
    const mime = this.selectedFileMimeType;
    if (mime.startsWith('image/')) {
      this.filePreviewType = 'image';
      this.filePreviewUrl = this.asDataUrl(mime, arrayBuffer);
      return;
    }
    if (mime === 'application/pdf' || file.name.toLowerCase().endsWith('.pdf')) {
      this.filePreviewType = 'pdf';
      this.filePreviewTextSnippet = `${file.name} (${Math.ceil(file.size / 1024)} KB)`;
      return;
    }
    if (mime.startsWith('text/') || file.name.toLowerCase().endsWith('.txt')) {
      this.filePreviewType = 'text';
      return;
    }
    this.filePreviewType = 'generic';
    this.filePreviewTextSnippet = `${file.name} (${Math.ceil(file.size / 1024)} KB)`;
  }

  private asDataUrl(mimeType: string, arrayBuffer: ArrayBuffer): string {
    return `data:${mimeType};base64,${this.toBase64(arrayBuffer)}`;
  }

  private readFileAsArrayBuffer(file: File): Promise<ArrayBuffer> {
    if (typeof file.arrayBuffer === 'function') {
      return file.arrayBuffer();
    }
    return new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = () => resolve((reader.result as ArrayBuffer) || new ArrayBuffer(0));
      reader.onerror = () => reject(reader.error || new Error('Failed to read file'));
      reader.readAsArrayBuffer(file);
    });
  }

  private readFileAsText(file: File): Promise<string> {
    if (typeof file.text === 'function') {
      return file.text();
    }
    return new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = () => resolve((reader.result as string) || '');
      reader.onerror = () => reject(reader.error || new Error('Failed to read file as text'));
      reader.readAsText(file);
    });
  }
}
