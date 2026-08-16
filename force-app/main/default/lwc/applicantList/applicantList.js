import { LightningElement, wire } from 'lwc';
import getApplicants from '@salesforce/apex/ApplicantListController.getApplicants';

const COLUMNS = [
    {
        label: 'Applicant',
        fieldName: 'recordUrl',
        type: 'url',
        typeAttributes: { label: { fieldName: 'name' }, target: '_self' }
    },
    { label: 'Email', fieldName: 'email', type: 'email' },
    { label: 'Mobile', fieldName: 'mobile', type: 'phone' },
    { label: 'City', fieldName: 'city' },
    { label: 'State', fieldName: 'state', fixedWidth: 100 },
    {
        label: 'Date of Birth',
        fieldName: 'birthdate',
        type: 'date-local',
        typeAttributes: { day: '2-digit', month: 'short', year: 'numeric' }
    }
];

export default class ApplicantList extends LightningElement {
    columns = COLUMNS;
    rows = [];
    error;
    loaded = false;

    @wire(getApplicants)
    wiredApplicants({ data, error }) {
        if (data) {
            this.rows = data.map((account) => ({
                id: account.Id,
                recordUrl: `/lightning/r/Account/${account.Id}/view`,
                name: account.Name,
                email: account.PersonEmail,
                mobile: account.PersonMobilePhone,
                city: account.PersonMailingCity,
                state: account.PersonMailingStateCode,
                birthdate: account.PersonBirthdate
            }));
            this.error = undefined;
            this.loaded = true;
        } else if (error) {
            this.error = error?.body?.message || 'Unable to load applicants.';
            this.rows = [];
            this.loaded = true;
        }
    }

    get hasRows() {
        return this.rows.length > 0;
    }

    get isEmpty() {
        return this.loaded && !this.error && this.rows.length === 0;
    }

    get isLoading() {
        return !this.loaded;
    }

    get countLabel() {
        const n = this.rows.length;
        return `${n} applicant${n === 1 ? '' : 's'}`;
    }
}
