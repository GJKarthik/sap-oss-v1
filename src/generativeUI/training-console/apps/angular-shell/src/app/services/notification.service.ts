import { Injectable } from '@angular/core';

@Injectable({
  providedIn: 'root'
})
export class NotificationService {
  
  async requestPermission(): Promise<boolean> {
    if (!('Notification' in window)) {
      console.warn('Browser does not support desktop notifications');
      return false;
    }
    
    // Avoid re-prompting if already granted/denied
    if (Notification.permission === 'granted') return true;
    if (Notification.permission === 'denied') return false;
    
    try {
      const permission = await Notification.requestPermission();
      return permission === 'granted';
    } catch (e) {
      console.error('Failed to request notification permission', e);
      return false;
    }
  }

  notify(title: string, options?: NotificationOptions) {
    if (!('Notification' in window)) return;
    
    if (Notification.permission === 'granted') {
      new Notification(title, options);
    }
  }
}
