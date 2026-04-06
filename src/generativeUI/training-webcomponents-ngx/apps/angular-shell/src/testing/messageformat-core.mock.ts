type Params = Record<string, unknown>;

function replaceNamedParams(template: string, params: Params): string {
  return template.replace(/\{(\w+)\}/g, (match, key) => {
    const value = params[key];
    return value == null ? match : String(value);
  });
}

function selectPluralForm(locale: string, count: number, forms: Record<string, string>): string {
  const exact = forms[`=${count}`];
  if (exact != null) {
    return exact;
  }

  const category = new Intl.PluralRules(locale).select(count);
  return forms[category] ?? forms['other'] ?? '';
}

function parsePluralForms(body: string): Record<string, string> {
  const forms: Record<string, string> = {};
  let index = 0;

  while (index < body.length) {
    while (/\s/.test(body[index] ?? '')) {
      index += 1;
    }
    if (index >= body.length) {
      break;
    }

    const keyStart = index;
    while (index < body.length && !/\s|\{/.test(body[index])) {
      index += 1;
    }
    const key = body.slice(keyStart, index);

    while (/\s/.test(body[index] ?? '')) {
      index += 1;
    }
    if (body[index] !== '{') {
      break;
    }

    let depth = 0;
    const valueStart = index + 1;
    while (index < body.length) {
      if (body[index] === '{') {
        depth += 1;
      } else if (body[index] === '}') {
        depth -= 1;
        if (depth === 0) {
          forms[key] = body.slice(valueStart, index);
          index += 1;
          break;
        }
      }
      index += 1;
    }
  }

  return forms;
}

function evaluatePlurals(message: string, locale: string, params: Params): string {
  let result = '';
  let index = 0;

  while (index < message.length) {
    const pluralStart = message.indexOf(', plural,', index);
    if (pluralStart === -1) {
      result += message.slice(index);
      break;
    }

    let blockStart = pluralStart;
    while (blockStart >= 0 && message[blockStart] !== '{') {
      blockStart -= 1;
    }
    if (blockStart < 0) {
      result += message.slice(index);
      break;
    }

    result += message.slice(index, blockStart);

    const variable = message.slice(blockStart + 1, pluralStart).trim();
    let cursor = pluralStart + ', plural,'.length;
    let depth = 1;
    const formsStart = cursor;

    while (cursor < message.length) {
      if (message[cursor] === '{') {
        depth += 1;
      } else if (message[cursor] === '}') {
        depth -= 1;
        if (depth === 0) {
          break;
        }
      }
      cursor += 1;
    }

    const forms = parsePluralForms(message.slice(formsStart, cursor));
    const count = Number(params[variable] ?? 0);
    result += selectPluralForm(locale, count, forms);
    index = cursor + 1;
  }

  return result;
}

export default class MessageFormat {
  constructor(private readonly locale: string) {}

  compile(message: string): (params: Params) => string {
    return (params: Params) => replaceNamedParams(evaluatePlurals(message, this.locale, params), params);
  }
}
