import { TestBed, fakeAsync, tick } from '@angular/core/testing';
import { ToastService, ToastType, Toast } from './toast.service';

describe('ToastService', () => {
  let service: ToastService;

  beforeEach(() => {
    TestBed.configureTestingModule({});
    service = TestBed.inject(ToastService);
  });

  it('should be created', () => {
    expect(service).toBeTruthy();
  });

  describe('show()', () => {
    it('should add a toast to the list', () => {
      const id = service.show('Test message', 'info');
      expect(service.toasts().length).toBe(1);
      expect(service.toasts()[0].message).toBe('Test message');
      expect(service.toasts()[0].type).toBe('info');
      expect(id).toContain('toast-');
    });

    it('should auto-dismiss after duration', fakeAsync(() => {
      service.show('Test', 'info', undefined, 1000);
      expect(service.toasts().length).toBe(1);
      tick(1000);
      expect(service.toasts().length).toBe(0);
    }));

    it('should not auto-dismiss when duration is 0', fakeAsync(() => {
      service.show('Test', 'info', undefined, 0);
      expect(service.toasts().length).toBe(1);
      tick(5000);
      expect(service.toasts().length).toBe(1);
    }));
  });

  describe('convenience methods', () => {
    it('success() should create a success toast', () => {
      service.success('Success message');
      expect(service.toasts()[0].type).toBe('success');
      expect(service.toasts()[0].title).toBe('Success');
    });

    it('error() should create an error toast with longer duration', () => {
      service.error('Error message');
      expect(service.toasts()[0].type).toBe('error');
      expect(service.toasts()[0].title).toBe('Error');
      expect(service.toasts()[0].duration).toBe(8000);
    });

    it('warning() should create a warning toast', () => {
      service.warning('Warning message');
      expect(service.toasts()[0].type).toBe('warning');
      expect(service.toasts()[0].title).toBe('Warning');
    });

    it('info() should create an info toast', () => {
      service.info('Info message');
      expect(service.toasts()[0].type).toBe('info');
      expect(service.toasts()[0].title).toBe('Info');
    });
  });

  describe('dismiss()', () => {
    it('should remove a specific toast by id', () => {
      const id1 = service.show('Message 1');
      const id2 = service.show('Message 2');
      expect(service.toasts().length).toBe(2);

      service.dismiss(id1);
      expect(service.toasts().length).toBe(1);
      expect(service.toasts()[0].message).toBe('Message 2');
    });

    it('should handle dismissing non-existent id gracefully', () => {
      service.show('Test');
      expect(service.toasts().length).toBe(1);
      service.dismiss('non-existent-id');
      expect(service.toasts().length).toBe(1);
    });
  });

  describe('dismissAll()', () => {
    it('should remove all toasts', () => {
      service.show('Message 1');
      service.show('Message 2');
      service.show('Message 3');
      expect(service.toasts().length).toBe(3);

      service.dismissAll();
      expect(service.toasts().length).toBe(0);
    });
  });

  describe('hasToasts()', () => {
    it('should return false when empty', () => {
      expect(service.hasToasts()).toBe(false);
    });

    it('should return true when toasts exist', () => {
      service.show('Test');
      expect(service.hasToasts()).toBe(true);
    });
  });
});