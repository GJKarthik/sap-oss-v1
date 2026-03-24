import { NO_ERRORS_SCHEMA } from '@angular/core';
import { ComponentFixture, TestBed } from '@angular/core/testing';
import { provideHttpClient } from '@angular/common/http';
import { HttpTestingController, provideHttpClientTesting } from '@angular/common/http/testing';
import { GovernanceComponent } from './governance.component';
import { AuthService } from '../../services/auth.service';
import { environment } from '../../../environments/environment';

describe('GovernanceComponent', () => {
  let fixture: ComponentFixture<GovernanceComponent>;
  let httpMock: HttpTestingController;

  async function setup(role: string): Promise<void> {
    await TestBed.configureTestingModule({
      imports: [GovernanceComponent],
      providers: [
        provideHttpClient(),
        provideHttpClientTesting(),
        {
          provide: AuthService,
          useValue: {
            getUser: () => ({ username: 'user', role }),
          },
        },
      ],
    })
      .overrideComponent(GovernanceComponent, {
        add: {
          schemas: [NO_ERRORS_SCHEMA],
        },
      })
      .compileComponents();

    fixture = TestBed.createComponent(GovernanceComponent);
    httpMock = TestBed.inject(HttpTestingController);
  }

  afterEach(() => {
    httpMock?.verify();
    TestBed.resetTestingModule();
  });

  it('hides mutating controls for viewer sessions', async () => {
    await setup('viewer');
    fixture.detectChanges();

    httpMock.expectOne(`${environment.apiBaseUrl}/governance`).flush({
      rules: [
        { id: 'rule-1', name: 'PII Detection', rule_type: 'content-filter', active: true },
      ],
      total: 1,
    });
    fixture.detectChanges();

    const text = fixture.nativeElement.textContent;
    expect(text).toContain('Viewer mode: governance changes are disabled.');
    expect(text).toContain('Read only');
    expect(text).not.toContain('Add Rule');
    expect(text).not.toContain('Disable');
  });

  it('shows mutating controls for admin sessions', async () => {
    await setup('admin');
    fixture.detectChanges();

    httpMock.expectOne(`${environment.apiBaseUrl}/governance`).flush({
      rules: [
        { id: 'rule-1', name: 'PII Detection', rule_type: 'content-filter', active: true },
      ],
      total: 1,
    });
    fixture.detectChanges();

    const text = fixture.nativeElement.textContent;
    expect(text).toContain('Add Rule');
    expect(text).toContain('Disable');
    expect(text).not.toContain('Viewer mode: governance changes are disabled.');
  });
});
