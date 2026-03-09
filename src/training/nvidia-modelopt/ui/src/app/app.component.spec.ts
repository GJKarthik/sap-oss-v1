import { ComponentFixture, TestBed } from '@angular/core/testing';
import { RouterTestingModule } from '@angular/router/testing';
import { AppComponent } from './app.component';

describe('AppComponent', () => {
  let component: AppComponent;
  let fixture: ComponentFixture<AppComponent>;

  beforeEach(async () => {
    await TestBed.configureTestingModule({
      imports: [AppComponent, RouterTestingModule],
    }).compileComponents();

    fixture = TestBed.createComponent(AppComponent);
    component = fixture.componentInstance;
  });

  it('should create the app', () => {
    expect(component).toBeTruthy();
  });

  it('should initialise apiKey from sessionStorage', () => {
    sessionStorage.removeItem('modelopt_api_key');
    const fresh = TestBed.createComponent(AppComponent).componentInstance;
    expect(fresh.apiKey).toBe('');
  });

  it('saveApiKey writes to sessionStorage', () => {
    component.apiKey = 'test-key-123';
    spyOn(window, 'alert'); // suppress alert dialog
    component.saveApiKey();
    expect(sessionStorage.getItem('modelopt_api_key')).toBe('test-key-123');
  });

  it('onApiKeyChange updates apiKey from input event', () => {
    const event = { target: { value: 'new-key' } } as unknown as Event;
    component.onApiKeyChange(event);
    expect(component.apiKey).toBe('new-key');
  });

  afterEach(() => sessionStorage.removeItem('modelopt_api_key'));
});

