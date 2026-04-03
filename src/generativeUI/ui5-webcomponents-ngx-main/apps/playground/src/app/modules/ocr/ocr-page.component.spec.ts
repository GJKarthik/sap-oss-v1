import { HttpClient } from '@angular/common/http';
import { of, throwError } from 'rxjs';
import { OcrPageComponent } from './ocr-page.component';
import { LiveDemoHealthService } from '../../core/live-demo-health.service';

function makeHttp() {
  return {
    get: jest.fn(),
    post: jest.fn(),
  } as unknown as HttpClient;
}

function makeHealthService() {
  return {
    checkRouteReadiness: jest.fn().mockReturnValue(
      of({ route: 'ocr', blocking: false, checks: [] }),
    ),
  } as unknown as LiveDemoHealthService;
}

describe('OcrPageComponent', () => {
  it('processes OCR text and stores extraction result', () => {
    const http = makeHttp();
    (http.get as jest.Mock).mockReturnValue(of({ data: [] }));
    (http.post as jest.Mock).mockReturnValue(
      of({
        extraction: {
          original_ar: 'إجمالي الفاتورة ١٠٠',
          translated_en: 'Total invoice 100',
          financial_fields: [{ key: 'grand_total', value: '100', confidence: 0.8 }],
          line_items: [],
        },
      }),
    );
    const health = makeHealthService();
    const component = new OcrPageComponent(http, health);
    component.ngOnInit();
    component.documentText = 'إجمالي الفاتورة ١٠٠';

    component.processDocument();

    expect(http.post).toHaveBeenCalled();
    expect(component.result?.translated_en).toContain('Total invoice');
  });

  it('loads OCR history documents', () => {
    const http = makeHttp();
    (http.get as jest.Mock).mockReturnValue(
      of({
        data: [{ id: 'ocrdoc_1', file_name: 'invoice-a.txt' }],
      }),
    );
    const health = makeHealthService();
    const component = new OcrPageComponent(http, health);

    component.ngOnInit();

    expect(component.recentDocuments).toEqual([
      { id: 'ocrdoc_1', label: 'invoice-a.txt' },
    ]);
  });

  it('does not call OCR API when route is blocked', () => {
    const http = makeHttp();
    const health = makeHealthService();
    (health.checkRouteReadiness as jest.Mock).mockReturnValue(
      of({
        route: 'ocr',
        blocking: true,
        checks: [{ name: 'OpenAI', ok: false, status: 503, url: '/health' }],
      }),
    );
    const component = new OcrPageComponent(http, health);
    component.ngOnInit();

    component.processDocument();

    expect(component.routeBlocked).toBe(true);
    expect(http.post).not.toHaveBeenCalled();
  });

  it('captures process error from backend', () => {
    const http = makeHttp();
    (http.get as jest.Mock).mockReturnValue(of({ data: [] }));
    (http.post as jest.Mock).mockReturnValue(
      throwError(() => new Error('ocr unavailable')),
    );
    const health = makeHealthService();
    const component = new OcrPageComponent(http, health);
    component.ngOnInit();

    component.processDocument();

    expect(component.lastError).toContain('ocr unavailable');
  });

  it('sends uploaded file metadata with OCR payload', () => {
    const http = makeHttp();
    (http.get as jest.Mock).mockReturnValue(of({ data: [] }));
    (http.post as jest.Mock).mockReturnValue(of({ extraction: {} }));
    const health = makeHealthService();
    const component = new OcrPageComponent(http, health);
    component.ngOnInit();
    component.selectedFileName = 'invoice.png';
    component.selectedFileMimeType = 'image/png';
    component.selectedFileBase64 = 'ZmFrZQ==';

    component.processDocument();

    expect(http.post).toHaveBeenCalledWith(
      expect.any(String),
      expect.objectContaining({
        file_name: 'invoice.png',
        mime_type: 'image/png',
        file_content_base64: 'ZmFrZQ==',
      }),
    );
  });

  it('toggles drag-over state for dropzone interactions', () => {
    const http = makeHttp();
    const health = makeHealthService();
    const component = new OcrPageComponent(http, health);

    component.onDragOver({ preventDefault: jest.fn() } as unknown as DragEvent);
    expect(component.isDragOver).toBe(true);

    component.onDragLeave({ preventDefault: jest.fn() } as unknown as DragEvent);
    expect(component.isDragOver).toBe(false);
  });

  it('processes dropped text file and updates preview/text', async () => {
    const http = makeHttp();
    const health = makeHealthService();
    const component = new OcrPageComponent(http, health);
    const file = new File(['invoice 123'], 'invoice.txt', { type: 'text/plain' });
    const event = {
      preventDefault: jest.fn(),
      dataTransfer: { files: [file] },
    } as unknown as DragEvent;

    await component.onDrop(event);

    expect(component.selectedFileName).toBe('invoice.txt');
    expect(component.filePreviewType).toBe('text');
    expect(component.documentText).toContain('invoice 123');
  });

  it('clears selected file and preview state', () => {
    const http = makeHttp();
    const health = makeHealthService();
    const component = new OcrPageComponent(http, health);
    component.selectedFileName = 'invoice.pdf';
    component.selectedFileMimeType = 'application/pdf';
    component.selectedFileBase64 = 'ZmFrZQ==';
    component.filePreviewType = 'pdf';
    component.filePreviewUrl = 'data:application/pdf;base64,ZmFrZQ==';
    component.filePreviewTextSnippet = 'invoice.pdf (12 KB)';

    component.clearSelectedFile();

    expect(component.selectedFileName).toBe('');
    expect(component.selectedFileMimeType).toBe('');
    expect(component.selectedFileBase64).toBe('');
    expect(component.filePreviewType).toBe('');
    expect(component.filePreviewUrl).toBe('');
    expect(component.filePreviewTextSnippet).toBe('');
  });
});
